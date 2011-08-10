!--this is the w-node version
!--most stuff done layer-by-layer to save memory
!--provides Cs_opt2 1:nz
!--MPI: requires u,v on 0:nz, except bottom node 1:nz

subroutine lagrange_Ssim(S11,S12,S13,S22,S23,S33)
! The purpose of this subroutine is to (dynamically) calculate Cs_opt2
!   See Meneveau, Lund, Cabot, JFM, 319: 353-385 (1996)
!   DOI: 10.1017/S0022112096007379
use types,only:rprec
use param
use sim_param,only:u,v,w
use sgsmodule,only:F_LM,F_MM,Beta,Cs_opt2,opftime,count_clip,count_all,lagran_dt
use test_filtermodule
use messages
$if ($DEBUG)
use debug_mod
$endif
$if ($LVLSET)
  use level_set, only : level_set_lag_dyn, level_set_Cs_lag_dyn
$endif
$if ($DYN_TN)
use sgsmodule, only:F_ee2,F_deedt2,ee_past
$endif
$if ($MPI)
use mpi_defs, only:mpi_sync_real_array,MPI_SYNC_DOWNUP
$endif

implicit none

$if ($MPI)
  $define $lbz 0
$else
  $define $lbz 1
$endif

$if ($DEBUG)
logical, parameter :: DEBUG = .false.
$endif

real (rprec), dimension(ld,ny,nz) :: S11,S12,S13,S22,S23,S33
character (*), parameter :: sub_name = 'lagrange_Ssim'
real (rprec), parameter :: eps = 1.e-32_rprec

real(rprec), dimension(ld,ny) :: L11,L12,L13,L22,L23,L33
real(rprec), dimension(ld,ny) :: M11,M12,M13,M22,M23,M33
real(rprec), dimension(ld,ny) :: fourbeta

real(rprec), dimension(ld,ny) :: LM,MM,Tn,epsi,dumfac
real(rprec), dimension(ld,ny) :: ee_now

real(rprec), dimension(ld,ny) :: S_bar,S11_bar,S12_bar,&
     S13_bar,S22_bar,S23_bar,S33_bar,S_S11_bar, S_S12_bar,&
     S_S13_bar, S_S22_bar, S_S23_bar, S_S33_bar

real(rprec), dimension(ld,ny) :: u_bar,v_bar,w_bar
real(rprec), dimension(ld,ny) :: S
real(rprec) :: delta,const
real(rprec) :: opftdelta,powcoeff

character (64) :: fnamek, tempk

integer :: istart, iend, ihi, ilo, jhi, jlo
integer :: jz
integer :: ii
integer :: i, j

logical, save :: F_LM_MM_init = .false.

!---------------------------------------------------------------------
$if ($VERBOSE)
call enter_sub (sub_name)
$endif

! Set coefficients
    delta = filter_size*(dx*dy*dz)**(1._rprec/3._rprec)
    opftdelta = opftime*delta
    powcoeff = -1._rprec/8._rprec
    const = 2._rprec*delta**2

$if ($LVLSET)
  call level_set_lag_dyn (S11, S12, S13, S22, S23, S33)
$else
  Beta = 1._rprec  
$endif

! "Rearrange" F_LM, F_MM, F_ee2, F_deedt2 (running averages) so that 
!   their new positions (i,j,k) correspond to the current (i,j,k) particle
call interpolag_Ssim()

! For each horizontal level, calculate Lij(:,:) and Mij(:,:).  Then update
!   the running averages, F_LM(:,:,jz) and F_MM(:,:,jz), which are used to 
!   calculate Cs_opt2(:,:,jz).
do jz = 1,nz
    ! Reset counting variables for Cs clipping stats
    count_all = 0
    count_clip = 0

    ! Calculate Lij
        ! Interp u,v,w onto w-nodes and store result as u_bar,v_bar,w_bar
        ! (except for very first level which should be on uvp-nodes)
        if ( ((.not. USE_MPI) .or. (USE_MPI .and. coord == 0)) .and.  &
            (jz == 1) ) then  ! uvp-nodes
            u_bar(:,:) = u(:,:,1)
            v_bar(:,:) = v(:,:,1)
            w_bar(:,:) = .25_rprec*w(:,:,2)
       else  ! w-nodes
            u_bar(:,:) = .5_rprec*(u(:,:,jz) + u(:,:,jz-1)) 
            v_bar(:,:) = .5_rprec*(v(:,:,jz) + v(:,:,jz-1))  
            w_bar(:,:) = w(:,:,jz)
       end if
       
       ! First term before filtering (not the final value)
       L11=u_bar*u_bar
       L12=u_bar*v_bar
       L13=u_bar*w_bar
       L23=v_bar*w_bar
       L22=v_bar*v_bar
       L33=w_bar*w_bar
       
       ! Filter first term and add the second term to get the final value
       call test_filter(u_bar,G_test)   ! in-place filtering
       call test_filter(v_bar,G_test)
       call test_filter(w_bar,G_test)
       call test_filter(L11,G_test)  
       L11 = L11 - u_bar*u_bar  
       call test_filter(L12,G_test)
       L12 = L12 - u_bar*v_bar
       call test_filter(L13,G_test)
       L13 = L13 - u_bar*w_bar
       call test_filter(L22,G_test)
       L22 = L22 - v_bar*v_bar
       call test_filter(L23,G_test)
       L23 = L23 - v_bar*w_bar
       call test_filter(L33,G_test)
       L33 = L33 - w_bar*w_bar

    ! Calculate |S|
        S(:,:) = sqrt(2._rprec*(S11(:,:,jz)**2+S22(:,:,jz)**2+S33(:,:,jz)**2+&
            2._rprec*(S12(:,:,jz)**2+S13(:,:,jz)**2+S23(:,:,jz)**2)))

    ! Select Sij for this level for test-filtering, saving results as Sij_bar
    !   note: Sij is already on w-nodes
       S11_bar(:,:) = S11(:,:,jz)  
       S12_bar(:,:) = S12(:,:,jz)  
       S13_bar(:,:) = S13(:,:,jz)  
       S22_bar(:,:) = S22(:,:,jz)  
       S23_bar(:,:) = S23(:,:,jz)  
       S33_bar(:,:) = S33(:,:,jz)

       call test_filter(S11_bar,G_test)
       call test_filter(S12_bar,G_test)
       call test_filter(S13_bar,G_test)
       call test_filter(S22_bar,G_test)
       call test_filter(S23_bar,G_test)
       call test_filter(S33_bar,G_test)

    ! Calculate |S_bar| (the test-filtered Sij)      
        S_bar = sqrt(2._rprec*(S11_bar**2 + S22_bar**2 + S33_bar**2 +&
            2._rprec*(S12_bar**2 + S13_bar**2 + S23_bar**2)))

    ! Calculate |S|Sij then test-filter this quantity
       S_S11_bar(:,:) = S(:,:)*S11(:,:,jz)
       S_S12_bar(:,:) = S(:,:)*S12(:,:,jz)
       S_S13_bar(:,:) = S(:,:)*S13(:,:,jz)
       S_S22_bar(:,:) = S(:,:)*S22(:,:,jz)
       S_S23_bar(:,:) = S(:,:)*S23(:,:,jz)
       S_S33_bar(:,:) = S(:,:)*S33(:,:,jz)

       call test_filter(S_S11_bar,G_test)
       call test_filter(S_S12_bar,G_test)
       call test_filter(S_S13_bar,G_test)
       call test_filter(S_S22_bar,G_test)
       call test_filter(S_S23_bar,G_test)
       call test_filter(S_S33_bar,G_test)       
   
    ! Calculate Mij
        fourbeta=4._rprec*Beta(:,:,jz)

        M11 = const*(S_S11_bar - fourbeta*S_bar*S11_bar)
        M12 = const*(S_S12_bar - fourbeta*S_bar*S12_bar)
        M13 = const*(S_S13_bar - fourbeta*S_bar*S13_bar)
        M22 = const*(S_S22_bar - fourbeta*S_bar*S22_bar)
        M23 = const*(S_S23_bar - fourbeta*S_bar*S23_bar)
        M33 = const*(S_S33_bar - fourbeta*S_bar*S33_bar)
        
    ! Calculate LijMij and MijMij for each point in the plane
        LM=L11*M11+L22*M22+L33*M33+2._rprec*(L12*M12+L13*M13+L23*M23)
        MM = M11**2+M22**2+M33**2+2._rprec*(M12**2+M13**2+M23**2)
        
    ! Calculate ee_now (the current value of eij*eij)
            $if ($DYN_TN)       
            ee_now = L11**2+L22**2+L33**2+2._rprec*(L12**2+L13**2+L23**2) &
                    -2._rprec*LM*Cs_opt2(:,:,jz) + MM*Cs_opt2(:,:,jz)**2
            $endif   
            
    ! Initialize (???)
        if (inilag) then
            if ((.not. F_LM_MM_init) .and. (jt == cs_count .or. jt == DYN_init)) then
                print *,'F_MM and F_LM initialized' 
                F_MM (:,:,jz) = MM
                F_LM (:,:,jz) = 0.025_rprec*MM
                F_MM(ld-1:ld,:,jz)=1._rprec
                F_LM(ld-1:ld,:,jz)=1._rprec

                if (jz == 1) then
                    if ((.not. USE_MPI) .or. (USE_MPI .and. coord == 0)) then
                        write (*, *) 'LM(1, 1)=', LM(1, 1)
                        write (*, *) 'MM(1, 1)=', MM(1, 1)
                        write (*, *) 'M11(1, 1)=', M11(1, 1)
                        write (*, *) 'S_S11_bar(1, 1)=', S_S11_bar(1, 1)
                        write (*, *) 'S11(1, 1, 1)=', S11(1, 1, 1)
                        write (*, *) 'S(1, 1)=', S(1, 1)
                        write (*, *) 'S11_bar(1, 1)=', S11_bar(1, 1)
                        write (*, *) 'S_bar(1, 1)=', S_bar(1, 1)
                    endif
                endif

                if (jz == nz) F_LM_MM_init = .true.
            endif
        endif
   
    ! Inflow (???)
        if (inflow) then  !--may need to change this
            iend = floor (buff_end * nx + 1._rprec)
            istart = floor ((buff_end - buff_len) * nx + 1._rprec)

            Tn=merge(.1_rprec*const*S**2,MM,MM.le..1_rprec*const*S**2)
            MM=Tn
           
            if (istart > iend) then
                write (*, *) 'lagrange_Ssim: istart > iend'
                stop
            endif      
            do i = istart, iend
                ii = modulo (i - 1, nx) + 1
                LM(ii, :) = 0._rprec
                F_LM(ii, :, jz) = 0._rprec
            enddo
        endif
    
    ! Update running averages (F_LM, F_MM, F_ee2, F_deedt2)
        ! Determine averaging timescale 
            $if ($DYN_TN)   ! based on Taylor timescale
                Tn = 4._rprec*pi*sqrt(F_ee2(:,:,jz)/F_deedt2(:,:,jz))   
            $else           ! based on Meneveau, Cabot, Lund paper (JFM 1996)
                Tn = max (F_LM(:,:,jz) * F_MM(:,:,jz), eps)
                Tn = opftdelta*(Tn**powcoeff)    
            $endif   
            
        ! Calculate new running average = old*(1-epsi) + instantaneous*epsi            
            dumfac = lagran_dt/Tn
            epsi = dumfac / (1._rprec + dumfac)  
           
            F_LM(:,:,jz)=(epsi*LM + (1.0_rprec-epsi)*F_LM(:,:,jz))
            F_MM(:,:,jz)=(epsi*MM + (1.0_rprec-epsi)*F_MM(:,:,jz))
            F_LM(:,:,jz)= max (eps, F_LM(:,:,jz))    ! clipping to avoid instability       

            $if ($DYN_TN)
            ! note: the instantaneous value of the derivative is a Lagrangian average
            F_ee2(:,:,jz) = epsi*ee_now**2 + (1._rprec-epsi)*F_ee2(:,:,jz)             
            F_deedt2(:,:,jz) = epsi*( ((ee_now-ee_past(:,:,jz))/lagran_dt)**2 ) &
                                  + (1._rprec-epsi)*F_deedt2(:,:,jz)
            ee_past(:,:,jz) = ee_now
            $endif   
            
    ! Calculate Cs_opt2 (use only one of the methods below)
        ! Standard method - LASS
        ! Added +eps to avoid division by zero
            Cs_opt2(:,:,jz) = F_LM(:,:,jz) / (F_MM(:,:,jz) + eps)
            Cs_opt2(ld-1:ld,:,jz) = 0._rprec          
        ! 9-point average
            !do i=1,nx
            !do j=1,ny
            !    ilo=i-1; ihi=i+1; jlo=j-1;  jhi=j+1
            !    if (ilo.eq.0) ilo=nx
            !    if (jlo.eq.0) jlo=ny
            !    if (ihi.eq.nx+1) ihi=1
            !    if (jhi.eq.ny+1) jhi=1
            !    Cs_opt2(i,j,jz) = (LM(i,j)+LM(ilo,j)+LM(ihi,j)+LM(ilo,jlo)+&
            !                       LM(ihi,jlo)+LM(i,jlo)+LM(ilo,jhi)+LM(i,jhi)+LM(ihi,jhi))/ &
            !                      (MM(i,j)+MM(ilo,j)+MM(ihi,j)+MM(ilo,jlo)+&
            !                       MM(ihi,jlo)+MM(i,jlo)+MM(ilo,jhi)+MM(i,jhi)+MM(ihi,jhi))
            !enddo
            !enddo
        ! Directly
            !Cs_opt2(:,:,jz) = LM(:,:)/MM(:,:)

    ! Count how often Cs is clipped
        do i=1,nx
        do j=1,ny
            if (Cs_opt2(i,j,jz).lt.eps) count_clip = count_clip + 1
            count_all = count_all + 1
        enddo
        enddo
        ! Clip Cs if necessary
        Cs_opt2(:,:,jz)= max (eps, Cs_opt2(:,:,jz)) 
   
    ! Write average Tn for this level to file
        ! Create filename
        if ((jz+coord*(nz-1)).lt.10) then
            write (tempk, '(i1)') (jz + coord*(nz-1))
        elseif ((jz+coord*(nz-1)).lt.100) then
            write (tempk, '(i2)') (jz + coord*(nz-1))
        endif      
        $if ($DYN_TN)
        fnamek = trim('output/Tn_new_') // trim(tempk)
        $else
        fnamek = trim('output/Tn_old_') // trim(tempk)
        $endif
        fnamek = trim(fnamek) // trim('.dat')
       
        ! Write
        open(unit=2,file=fnamek,action='write',position='append',form='formatted')
        write(2,*) jt,sum(Tn(1:nx,1:ny))/(nx*ny)
        close(2)
        
    ! Also write clipping stats to file
        fnamek = trim('output/clip_') // trim(tempk)
        fnamek = trim(fnamek) // trim('.dat')   
        open(unit=2,file=fnamek,action='write',position='append',form='formatted')
        write(2,*) jt,count_clip,count_all,real(count_clip)/real(count_all)
        close(2)   
    
end do
! this ends the main jz=1,nz loop     -----------------------now repeat for other horiz slices

! Share new data between overlapping nodes
    $if ($MPI)
        call mpi_sync_real_array( F_LM, MPI_SYNC_DOWNUP )  
        call mpi_sync_real_array( F_MM, MPI_SYNC_DOWNUP )            
        $if ($DYN_TN)
            call mpi_sync_real_array( F_ee2, MPI_SYNC_DOWNUP )
            call mpi_sync_real_array( F_deedt2, MPI_SYNC_DOWNUP )
            call mpi_sync_real_array( ee_past, MPI_SYNC_DOWNUP )
        $endif 
    $endif   

$if ($DEBUG)
if (DEBUG) then
    call DEBUG_write (F_LM(:, :, 1:nz), 'lagrange_Ssim.F_LM')
    call DEBUG_write (F_MM(:, :, 1:nz), 'lagrange_Ssim.F_MM')
    call DEBUG_write (Cs_opt2(:, :, 1:nz), 'lagrange_Ssim.Cs_opt2')
end if
$endif

$if ($LVLSET)
    call level_set_Cs_lag_dyn ()
$endif

$if ($CFL_DT)
    ! Reset variable for use during next set of cs_count timesteps
    lagran_dt = 0.0_rprec
$endif

$if ($VERBOSE)
    call exit_sub(sub_name)
$endif

end subroutine lagrange_Ssim
