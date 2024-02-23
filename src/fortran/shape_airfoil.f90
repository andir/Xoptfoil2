! MIT License
! Copyright (C) 2017-2019 Daniel Prosser
! Copyright (c) 2024 Jochen Guenzel 

module shape_airfoil

  !-------------------------------------------------------------------------
  ! Create an airfoil shape from design variables
  !-------------------------------------------------------------------------

  use os_util
  use airfoil_base,           only : airfoil_type
  use shape_bezier,           only : shape_bezier_type
  use shape_hicks_henne,      only : shape_hh_type
  use shape_camb_thick,       only : shape_camb_thick_type
  use xfoil_driver,           only : flap_spec_type

  implicit none
  private 

  ! --- shape master type specifying how airfoil will shaped ---------------------------- 

  integer, parameter, public  :: HICKS_HENNE = 1          ! shape types 
  integer, parameter, public  :: BEZIER      = 2
  integer, parameter, public  :: CAMB_THICK  = 3

  type shape_spec_type
    integer                       :: type                 ! HICKS_HENNE or BEZIER or ...
    character (:), allocatable    :: type_as_text         ! eg 'hicks-henne' 
    character (:), allocatable    :: camber_type          ! either '' or 'reflexed' or 'rear-loading' 
    
    integer                       :: ndv                  ! number of design variables 
    type(shape_hh_type)           :: hh                   ! specs for hicks-henne
    type(shape_bezier_type)       :: bezier               ! specs for bezier 
    type(shape_camb_thick_type)   :: camb_thick           ! specs for camb thick 

    type (flap_spec_type)         :: flap_spec

  end type

  public          :: shape_spec_type


  ! --- Public functions------------------------------------------------------- 

  public :: assess_shape
  public :: set_shape_spec
  public :: get_seed_foil
  public :: get_ndv_of_shape
  public :: get_ndv_of_flaps
  public :: get_dv0_of_shape
  public :: get_dv0_of_flaps
  public :: get_dv_initial_perturb_of_shape
  public :: get_dv_initial_perturb_of_flaps
  public :: create_airfoil_bezier
  public :: create_airfoil_camb_thick
  public :: create_airfoil_hicks_henne
  public :: get_flap_angles_optimized

  ! --- Public static ------------------------------------------------------- 

  type (shape_spec_type), public    :: shape_spec           ! main shape specification, static 


  ! ---- private, static -------------------------------------------------------
  
  type (airfoil_type)               :: seed_foil


contains

  subroutine assess_shape ()

    !-----------------------------------------------------------------------------
    !! make an assessment of defined shape functions if it's suitable for optimization  
    !-----------------------------------------------------------------------------

    use print_util
    use commons,         only : show_details 

    integer             :: ndv, ndv_top, ndv_bot, ndv_flap
    logical             :: top_reversal, bot_reversal 

    if (.not. show_details) return 

    ! is airfoil reflexed or has rear-loading? Maybe increase design variables... 

    top_reversal = .false.
    bot_reversal = .false.

    if (shape_spec%camber_type == 'reflexed') then 
      call print_note ("1 reversal on Top side - likely the airfoil will be ", 3, no_crlf=.true.)
      call print_colored (COLOR_NORMAL, "reflexed")
      print *
      top_reversal = .true.
    else if (shape_spec%camber_type == 'rear-loading') then 
      call print_note ("1 reversal on Bot side - likely the airfoil will have ", 3, no_crlf=.true.)
      call print_colored (COLOR_NORMAL, 'rear-loading')
      print *
      bot_reversal = .true.
    end if 

    ! Assess design variables  depending on shape function 

    call print_action   ("Using shape functions ", no_crlf=.true.)
    call print_colored  (COLOR_FEATURE, shape_spec%type_as_text)
    call print_colored (COLOR_NOTE, " to create airfoils")
    print *
 

    if (shape_spec%type == BEZIER) then 

      call assess_side_bezier ("Top", shape_spec%bezier%ncp_top, top_reversal, ndv_top)
      call assess_side_bezier ("Bot", shape_spec%bezier%ncp_bot, bot_reversal, ndv_bot)
      ndv = ndv_top + ndv_bot 

    else if (shape_spec%type == HICKS_HENNE) then

      call assess_side_hh ("Top", shape_spec%hh%nfunctions_top, top_reversal, ndv_top)
      call assess_side_hh ("Bot", shape_spec%hh%nfunctions_bot, bot_reversal, ndv_bot)
      ndv = ndv_top + ndv_bot 

    else if (shape_spec%type == CAMB_THICK) then

      ndv = shape_spec%camb_thick%ndv

    else 

      ndv = 0 

    end if 

    ! Flaps to be optimized? 

    ndv_flap = shape_spec%flap_spec%ndv

    if (ndv_flap > 0 ) then 

      ndv = ndv + ndv_flap 
      call print_action   ("There are "//stri(ndv_flap)//" operationg points with ", no_crlf=.true.)
      call print_colored  (COLOR_FEATURE, "flap optimization")
      print *

    end if 

    call print_action   ("A total of "//stri(ndv)//" design variables will be optimized")

  end subroutine



  subroutine assess_side_bezier (side, ncp, has_reversal, ndv)

    !-----------------------------------------------------------------------------
    !! assess top or bot side of bezier spec  
    !-----------------------------------------------------------------------------

    use print_util
    use shape_bezier,     only : ncp_to_ndv

    character (*), intent(in)     :: side
    logical, intent(in)           :: has_reversal 
    integer, intent(in)           :: ncp
    integer, intent(out)          :: ndv


    ndv = ncp_to_ndv(ncp)
    call print_text (side//" side  ", indent=5, no_crlf=.true.) 
    call print_text (stri(ncp)// " bezier control points - needs "//stri(ndv)//" design variables") 

    if (has_reversal .and. (ncp <= 5)) then 
      call print_note ("Because of curve reversal, consider to increase no of control points",5)
    end if 

  end subroutine


  subroutine assess_side_hh (side, nfunctions, has_reversal, ndv)

    !-----------------------------------------------------------------------------
    !! assess top or bot side of bezier spec  
    !-----------------------------------------------------------------------------

    use print_util
    use shape_hicks_henne,     only : nfunctions_to_ndv

    character (*), intent(in)     :: side
    logical, intent(in)           :: has_reversal 
    integer, intent(in)           :: nfunctions
    integer, intent(out)          :: ndv


    ndv = nfunctions_to_ndv (nfunctions)
    call print_text (side//" side  ", indent=5, no_crlf=.true.) 
    call print_text (stri(nfunctions)// " hicks henne functions - needs "//stri(ndv)//" design variables") 

    if (has_reversal .and. (nfunctions <= 3)) then 
      call print_note ("Because of curve reversal, consider to increase no of functions on "//&
                       side//" side",5)
    end if 

  end subroutine



  subroutine set_shape_spec (seed_foil_in, shape_spec_in)

    !-----------------------------------------------------------------------------
    !! set seed airfoil and shape_spec into static mod variable for later evaluation  
    !-----------------------------------------------------------------------------

    type (airfoil_type), intent(in)     :: seed_foil_in 
    type (shape_spec_type), intent(in)  :: shape_spec_in 

    seed_foil = seed_foil_in
    shape_spec = shape_spec_in

  end subroutine 



  subroutine get_seed_foil (seed_foil_out)

    !! gets seed_foil from static mod variable 

    type (airfoil_type), intent(out)  :: seed_foil_out 

    seed_foil_out = seed_foil

  end subroutine 



  subroutine create_airfoil_hicks_henne (dv, foil)

    !-----------------------------------------------------------------------------
    !! Creates an airfoil surface by perturbing an input "seed" airfoil
    !! with Hicks-Henne shape functions
    !-----------------------------------------------------------------------------

    use airfoil_base,           only : rebuild_from_sides
    use shape_hicks_henne,      only : nfunctions_to_ndv, hh_type, map_dv_to_hhs, hh_eval_side

    double precision, intent(in)    :: dv(:) 
    type(airfoil_type), intent(out) :: foil 

    double precision, allocatable   :: dv_top (:), dv_bot (:)
    integer                         :: ndv_top

    type (hh_type), allocatable     :: top_hh_specs (:) , bot_hh_specs (:)  
    double precision, allocatable   :: yt_new(:), yb_new(:)


    ! top side - design variables to hh functions 

    ndv_top = nfunctions_to_ndv (shape_spec%hh%nfunctions_top)
    dv_top = dv (1: ndv_top)

    call map_dv_to_hhs (dv_top, top_hh_specs)                       ! rebuild hicks henne specs 
    yt_new = seed_foil%top%y
    call hh_eval_side (top_hh_specs, seed_foil%top%x, yt_new )  ! and add hicks hennes to y 

    ! bot side - design variables to hh functions 

    if (.not. seed_foil%symmetrical) then

      dv_bot = dv (ndv_top + 1 : )

      call map_dv_to_hhs (dv_bot, bot_hh_specs)
      yb_new = seed_foil%bot%y                                  ! initial y value 
      call hh_eval_side (bot_hh_specs, seed_foil%bot%x, yb_new )
  
    else

      yb_new = -yt_new

    end if


    foil%top%x  = seed_foil%top%x
    foil%top%y  = yt_new
    foil%bot%x  = seed_foil%bot%x
    foil%bot%y  = yb_new

    call rebuild_from_sides (foil)

    ! !$omp critical
    !     if (ndv_top > 0) then 
    !       print '(A,F10.5,F12.6)', "## thickness", maxval(foil%y) * 100d0, dv (1)
    !     else
    !       print *, "bot", dv (1), bot_hh_specs(1)
    !     end if 
    ! !$omp end critical

    foil%is_hh_based  = .true.

    ! store seed airfoil information to be able to rebuild foil (write at the end) 

    foil%hh_seed_name  = seed_foil%name
    foil%hh_seed_top_y = seed_foil%top%y              ! seed y coordinates for independant rebuild(write)  
    foil%hh_seed_bot_y = seed_foil%bot%y             

    foil%top_hh%hhs    = top_hh_specs                        
    foil%bot_hh%hhs    = bot_hh_specs         

  end subroutine create_airfoil_hicks_henne



  subroutine create_airfoil_bezier (dv, foil) 

    !-----------------------------------------------------------------------------
    !! Create airfoil from bezier design variables
    !!  - seed is only needed to determine TE gap and number of points 
    !-----------------------------------------------------------------------------

    use airfoil_base,           only : split_foil_into_sides
    use airfoil_geometry,       only : te_gap 
    use shape_bezier,           only : bezier_spec_type
    use shape_bezier,           only : ncp_to_ndv_side
    use shape_bezier,           only : map_dv_to_bezier, bezier_create_airfoil

    double precision,  intent(in)   :: dv (:)
    type(airfoil_type), intent(out) :: foil 

    double precision, allocatable   :: dv_top (:), dv_bot (:)
    type(bezier_spec_type)  :: top_bezier, bot_bezier 
    double precision        :: side_te_gap
    integer                 :: ndv_top

    ! retrieve design variables for top and bot and rebuild bezier control points

    side_te_gap = te_gap (seed_foil) / 2
    ndv_top = ncp_to_ndv_side (shape_spec%bezier%ncp_top)
    dv_top  = dv (1: ndv_top)

    call map_dv_to_bezier ('Top', dv_top, side_te_gap, top_bezier)

    if (.not. seed_foil%symmetrical) then
      dv_bot = dv (ndv_top + 1 : )
      call map_dv_to_bezier ('Bot', dv_bot, side_te_gap, bot_bezier)
    else 
      bot_bezier = top_bezier
      bot_bezier%py = - top_bezier%py
    end if 

    ! build airfoil coordinates with control points 

    call bezier_create_airfoil (top_bezier, bot_bezier, size(seed_foil%x), foil%x, foil%y) 

        ! !$omp critical
        ! print * 
        ! print *,"d top x", top_bezier%px
        ! print *,"d top y", top_bezier%py
        ! print *,"d bot x", bot_bezier%px
        ! print *,"d bot y", bot_bezier%py
        ! !$omp end critical

    foil%is_bezier_based = .true.
    foil%top_bezier  = top_bezier                       ! could be useful to keep 
    foil%bot_bezier  = bot_bezier         

    call split_foil_into_sides (foil)

  end subroutine create_airfoil_bezier 



  subroutine create_airfoil_camb_thick (dv, foil)

    !-----------------------------------------------------------------------------
    !! Create airfoil by modifying thickness, camber and their positions, and 
    !!                             le radius and its blending distance  
    !-------------------------------------------------------------------------------
    
    use airfoil_geometry,       only : set_geometry_by_scale
    use shape_camb_thick,       only : map_dv_to_camb_thick

    double precision,  intent(in)   :: dv (:)
    type(airfoil_type), intent(out) :: foil    
    double precision        :: fmaxt, fxmaxt, fmaxc, fxmaxc, fle_radius, le_blend

    ! map design variables to camb_thick factors 

    call map_dv_to_camb_thick (dv, shape_spec%camb_thick, &
                               fmaxt, fxmaxt, fmaxc, fxmaxc, fle_radius, le_blend)

    ! change dgeometry with these factors (factor = 1.0 --> do nothing )

    foil = seed_foil
    call set_geometry_by_scale (foil, fmaxt, fxmaxt, fmaxc, fxmaxc, fle_radius, le_blend)                           
    
  end subroutine 


  
  function get_flap_angles_optimized  (dv) result (flap_angles)
  
    !----------------------------------------------------------------------------
    !! Get actual flap anglesfrom design vars (if there are...) 
    !! If the flap of an op point is fixed, return the fixed value (normally = 0) 
    !! dv:    all design variables! - of flaps are at the end  
    !----------------------------------------------------------------------------
  
    double precision, intent(in)   :: dv (:)
    double precision, allocatable  :: flap_angles (:)
  
    double precision                :: min_angle, max_angle
    integer      :: i, idv, ndv_flaps

  
    ndv_flaps = shape_spec%flap_spec%ndv
    allocate (flap_angles(ndv_flaps))

    ! early exit if there are no flaps optimized 
  
    if (ndv_flaps == 0) return 

    min_angle   = shape_spec%flap_spec%min_flap_angle
    max_angle   = shape_spec%flap_spec%max_flap_angle

    ! retrieve dv of flaps and map them to flap angle 
    
    idv = size(dv) - ndv_flaps  + 1                         ! flap design vars are at the end of dv 
  
    do i = 1, ndv_flaps  
      flap_angles (i) = min_angle + dv(idv) * (max_angle - min_angle)
      idv = idv + 1
    end do 
  
  end function  
  

  
  function get_ndv_of_shape () result (ndv)

    !----------------------------------------------------------------------------
    !! no of designvars of shape depending on shape type
    !----------------------------------------------------------------------------
  
    integer :: ndv
  
    if (shape_spec%type == CAMB_THICK) then    
      ndv = shape_spec%camb_thick%ndv
    else if (shape_spec%type == BEZIER) then
      ndv = shape_spec%bezier%ndv
    else if (shape_spec%type == HICKS_HENNE) then                                      
      ndv = shape_spec%hh%ndv
    else 
      ndv = 0 
    end if
  
  end function 



  function get_ndv_of_flaps () result (ndv)

    !----------------------------------------------------------------------------
    !! no of designvars of flap optimzation (defined in local 'flap_spec') 
    !----------------------------------------------------------------------------
  
    integer :: ndv
  
    ndv = shape_spec%flap_spec%ndv
  
  end function 



  function get_dv0_of_shape () result (dv0)

    !----------------------------------------------------------------------------
    !! designvars for design 0 (equals seed foil) depending on shape type
    !----------------------------------------------------------------------------
  
    use shape_hicks_henne,      only : hh_get_dv0
    use shape_bezier,           only : bezier_get_dv0


    double precision, allocatable :: dv0 (:) 
    integer                       :: ntop, nbot
  
    ! Set initial design
  
    if (shape_spec%type == CAMB_THICK) then    
  
      allocate (dv0 (shape_spec%camb_thick%ndv))
      dv0 = 0.5d0                                       ! equals no change to seed                                            
  
    else if (shape_spec%type == BEZIER) then
  
      dv0 = [bezier_get_dv0 ("Top", seed_foil%top_bezier), &
             bezier_get_dv0 ("Bot", seed_foil%bot_bezier)]
  
    else if (shape_spec%type == HICKS_HENNE) then                                      
      
      ntop = shape_spec%hh%nfunctions_top
      nbot = shape_spec%hh%nfunctions_bot
      dv0 = [hh_get_dv0 (ntop), hh_get_dv0 (nbot)]
  
    else 
  
      call my_stop ("Unknown shape type")
  
    end if
  
  end function 
  

  
  function get_dv0_of_flaps () result (dv0)
  
    !----------------------------------------------------------------------------
    !! start values of designvariables (0..1) for flaps to be optimized 
    !!    take angle defined in flap spec (from op sepc (input))
    !----------------------------------------------------------------------------
  
    double precision, allocatable :: dv0 (:) 
    double precision              :: min_angle, max_angle, start_angle
    integer                       :: ndv, idv

    ndv = shape_spec%flap_spec%ndv
    allocate (dv0 (ndv))
  
    if (ndv == 0) return                ! no flaps to optimize 
  
    min_angle   = shape_spec%flap_spec%min_flap_angle
    max_angle   = shape_spec%flap_spec%max_flap_angle

    ! map angle array to range 0..1

    do idv = 1, ndv 
      start_angle = shape_spec%flap_spec%start_flap_angle (idv) 
      dv0(idv) = (start_angle - min_angle / (max_angle - min_angle))
    end do 
      
  end function 
  


  function get_dv_initial_perturb_of_shape () result (dv_perturb)

    !----------------------------------------------------------------------------
    !! inital max. perturb of the designvars for design 0 depending on shape type
    !----------------------------------------------------------------------------
  
    use shape_hicks_henne,      only : hh_get_dv_inital_perturb
    use shape_bezier,           only : bezier_get_dv_inital_perturb

    double precision, allocatable :: dv_perturb (:)
    integer                       :: ntop, nbot
    double precision              :: initial
  
    ! Set initial design
  
    if (shape_spec%type == CAMB_THICK) then    
  
      ! dv is either scale ( 1+ dv) or delta x  highpoint    
      allocate (dv_perturb (shape_spec%camb_thick%ndv))
      dv_perturb = shape_spec%camb_thick%initial_perturb    ! simplified initial -> dv                                            
  
    else if (shape_spec%type == BEZIER) then
  
      initial = shape_spec%bezier%initial_perturb
      dv_perturb = [ bezier_get_dv_inital_perturb (initial, "Top", seed_foil%top_bezier), &
                     bezier_get_dv_inital_perturb (initial, "Bot", seed_foil%bot_bezier)]
  
    else if (shape_spec%type == HICKS_HENNE) then                                      
      
      ! concat dv0 of top and bot side hicks-henne functions 
      ntop = shape_spec%hh%nfunctions_top
      nbot = shape_spec%hh%nfunctions_bot
      initial = shape_spec%hh%initial_perturb

      dv_perturb = [hh_get_dv_inital_perturb (initial, ntop), &
                    hh_get_dv_inital_perturb (initial, nbot)]
  
    else 
  
      call my_stop ("Unknown shape type")
  
    end if
  
  end function 
  

  
  function get_dv_initial_perturb_of_flaps () result (dv_perturb)
  
    !----------------------------------------------------------------------------
    !! initial perturb of flap design vars (for initial design )
    !----------------------------------------------------------------------------
  
    double precision, allocatable :: dv_perturb (:) 
    integer                       :: ndv

    ndv = shape_spec%flap_spec%ndv  
    allocate (dv_perturb (ndv))
  
    if (ndv == 0) return                ! no flaps to optimize 
  
    ! initial perturb 5% of solution space (equals diff of min and max angle) 
    dv_perturb = 0.05d0      
      
  end function 
  


  subroutine write_dv_as_shape_data (step, iparticle, dv)

    !------------------------------------------------------------------------------
    !! Analysis: Write design variabales either as bezier or hicks henne to dump csv file 
    !------------------------------------------------------------------------------

    use commons,            only : design_subdir
    use shape_bezier,       only : bezier_spec_type
    use shape_bezier,       only : ncp_to_ndv_side, map_dv_to_bezier, write_bezier_file

    integer, intent(in)           :: step, iparticle
    double precision, intent(in)  :: dv (:) 

    double precision, allocatable   :: dv_shape_spec (:), dv_top(:), dv_bot(:)
    type(bezier_spec_type)          :: top_bezier, bot_bezier
    character (:), allocatable      :: dump_file, dump_name
    integer     :: ndv_top
    ! integer     :: i, iunit, stat, ndv_top

    ! Open dump file - either create new or append 

    dump_name = "dump_dv-"//stri(step)//"-"//stri(iparticle)

    ! open(unit=iunit, iostat=stat, file=dump_file, status='old')
    ! if (stat == 0) then 
    !   close(iunit) 
    !   print *,"before"
    !   open (unit=iunit, file=dump_file, status='old', position='append', action = 'readwrite', err=901)
    !   print *,"after"
    ! else 
    !   open (unit=iunit, file=dump_file, status='replace', action = 'readwrite', err=901)
    ! end if 

!$OMP CRITICAL
    if (shape_spec%type == BEZIER) then
        
      ! dv to bezier shape paramters 

      dv_shape_spec = dv (1 : shape_spec%bezier%ndv)

      ndv_top = ncp_to_ndv_side (shape_spec%bezier%ncp_top)
      dv_top = dv_shape_spec (1: ndv_top)
      call map_dv_to_bezier ('Top', dv_top, 0d0, top_bezier)

      dv_bot = dv_shape_spec (ndv_top + 1 : )
      call map_dv_to_bezier ('Bot', dv_bot, 0d0, bot_bezier)

      ! #todo handel symmetrical 
        ! if (.not. seed_foil%symmetrical) then
        !   dv_bot = dv_shape_spec (ndv_top + 1 : )
        !   call map_dv_to_bezier ('Bot', dv_bot, 0d0, bot_bezier)
        ! else 
        !   bot_bezier = top_bezier
        !   bot_bezier%py = - top_bezier%py
        ! end if 

      dump_file = design_subdir//dump_name//'.bez'
      call write_bezier_file (dump_file, dump_name, top_bezier, bot_bezier)
      ! write bezier data 
    
      ! write (iunit, '(I5,";",I5,";",A5)', advance='no') step, iparticle, 'Top'
      ! do i = 1,size(top_bezier%px)
      !   write (iunit, '(2(";",F12.8))', advance='no') top_bezier%px(i), top_bezier%py(i)
      ! end do 
      ! write (iunit,*)
    
      ! write (iunit, '(I5,";",I5,";",A5)', advance='no') step, iparticle, 'Bot'
      ! do i = 1,size(bot_bezier%px)
      !   write (iunit, '(2(";",F12.8))', advance='no') bot_bezier%px(i), bot_bezier%py(i)
      ! end do 
      ! write (iunit,*)
    

    else 

      dv_shape_spec = dv (1 : shape_spec%hh%ndv)

      call my_stop ("dump of hicks henne dv not implemented")

    end if
!$OMP END CRITICAL   

    return 

  ! 901 call print_warning ("Warning: unable to open "//dump_file//". Skipping ...")
  ! return
  end subroutine

end module shape_airfoil