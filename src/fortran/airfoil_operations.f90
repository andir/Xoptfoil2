! MIT License
! Copyright (C) 2017-2019 Daniel Prosser
! Copyright (c) 2024 Jochen Guenzel

module airfoil_operations

  ! Airfoil basic and geometry related functions 

  use os_util 
  use commons
  use print_util

  use spline,             only : spline_2D_type
  use shape_bezier,       only : bezier_spec_type  
  use shape_hicks_henne,  only : hh_spec_type

  implicit none
  private

  ! --- main airfoil type ------------------------------------------------------------

  ! Single side of airfoil 

  type side_airfoil_type 
    character(3)                  :: name             ! either 'Top' or 'Bot'
    double precision, allocatable :: x(:)
    double precision, allocatable :: y(:)
    double precision, allocatable :: curvature(:)
  end type 

  ! the airfoil type

  type airfoil_type 
    character(:), allocatable     :: name               ! name of the airfoil
    integer                       :: npoint             ! number of points
    double precision, allocatable :: x(:)               ! airfoil coordinates
    double precision, allocatable :: y(:)
    logical :: symmetrical    = .false.     ! #todo ->  init                     ! airfoil symmetrical? -> bot equals top side

    type (side_airfoil_type)      :: top                 ! top side of airfoil
    type (side_airfoil_type)      :: bot                 ! bottom side of airfoil 

    type (spline_2D_type)         :: spl                 ! cubic spline of coordinates 

    logical :: is_bezier_based = .false.                 ! was airfoil generated by bezier curve
    type (bezier_spec_type)       :: top_bezier          ! bezier curve specification if 'bezier_based'
    type (bezier_spec_type)       :: bot_bezier          ! bezier curve specification if 'bezier_based'

    logical :: is_hh_based = .false.                     ! was airfoil generated by hicks henne functions
    character (:), allocatable    :: hh_seed_name        ! name of seed airfoil hh are applied on 
    type (hh_spec_type)           :: top_hh              ! hh specs for top side 
    type (hh_spec_type)           :: bot_hh              ! hh specs for bot side 
 
  end type airfoil_type

  type panel_options_type   
    integer          :: npoint                  ! number of coordinate points 
    double precision :: le_bunch                ! panel bunching at le 0..1
    double precision :: te_bunch                ! panel bunching at te 0..1
  end type 

  public :: side_airfoil_type
  public :: airfoil_type
  public :: panel_options_type

  ! --- public functions ------------------------------------------------------------

  public :: load_airfoil
  public :: airfoil_write, airfoil_write_with_shapes
  public :: airfoil_write_to_unit
  public :: repanel 
  public :: repanel_and_normalize
  public :: repanel_bezier
  public :: rebuild_from_sides
  public :: split_foil_into_sides 
  public :: te_gap
  public :: is_normalized_coord
  public :: is_normalized
  public :: make_symmetrical
  public :: print_coordinate_data

  double precision, parameter    :: EPSILON = 1.d-10          ! distance LE to 0,0
  double precision, parameter    :: EPSILON_TE = 1.d-8        ! z-value of TE to be zero 
  double precision, parameter    :: LE_PANEL_FACTOR = 0.4     ! lenght LE panel / length prev panel

contains

  subroutine load_airfoil (filename, foil)

    !----------------------------------------------------------------------------
    !! Reads an airfoil from a file (checks ordering)
    !----------------------------------------------------------------------------

    character(*), intent(in) :: filename
    type(airfoil_type), intent(out) :: foil

    logical :: labeled
    integer :: i
    double precision, allocatable   :: xtemp(:), ytemp(:)

    if (trim(filename) == '') then
      call my_stop ('No airfoil file defined either in input file nor as command line argument')
    end if 

    ! Read number of points and allocate coordinates

    call airfoil_points(filename, foil%npoint, labeled)

    allocate(foil%x(foil%npoint))
    allocate(foil%y(foil%npoint))

    ! Read airfoil from file

    call airfoil_read(filename, foil%npoint, labeled, foil%name, foil%x, foil%y)

    ! Change point ordering to counterclockwise, if necessary

    if (foil%y(foil%npoint) > foil%y(1)) then
      
      call print_warning ('Changing point ordering to counter-clockwise ...')
      
      xtemp = foil%x
      ytemp = foil%y
      do i = 1, foil%npoint
        foil%x(i) = xtemp (foil%npoint-i+1)
        foil%y(i) = ytemp (foil%npoint-i+1)
      end do

    end if

  end subroutine



  subroutine airfoil_points(filename, npoints, labeled)

    !! get number of points from an airfoil file, is there a label?

    character(*), intent(in) :: filename
    integer, intent(out) :: npoints
    logical, intent(out) :: labeled

    integer :: iunit, ioerr
    double precision :: dummyx, dummyz

    ! Open airfoil file

    iunit = 12
    open(unit=iunit, file=filename, status='old', position='rewind', iostat=ioerr)
    if (ioerr /= 0) then
      call my_stop ('Cannot find airfoil file '//trim(filename))
    end if

    ! Read first line; determine if it is a title or not

    read(iunit,*,iostat=ioerr) dummyx, dummyz
    if (ioerr == 0) then
      npoints = 1
      labeled = .false.
    else
      npoints = 0
      labeled = .true.
    end if
    
    ! Read the rest of the lines

    do 
      read(iunit,*,end=500)
      npoints = npoints + 1
    end do

    ! Close the file

    500 close(iunit)

  end subroutine airfoil_points



  subroutine airfoil_read (filename, npoints, labeled, name, x, y)

    !! read an airfoil. Assumes the number of points is already known.
    !! Also checks for incorrect format.

    character(*), intent(in)                :: filename
    character(:), allocatable, intent(out)  :: name
    integer, intent(in)                     :: npoints
    logical, intent(in) :: labeled
    double precision, intent(inout) :: x (:), y(:)

    integer :: i, iunit, ioerr, nswitch
    double precision :: dir1, dir2

    ! Open airfoil file

    iunit = 12
    open(unit=iunit, file=filename, status='old', position='rewind', iostat=ioerr)
    if (ioerr /= 0) then
      call my_stop ('Cannot find airfoil file '//trim(filename))
    end if

    ! Read points from file

    name = repeat(' ',250)
    if (labeled) read(iunit,'(A)') name
    name = trim(adjustl(name))

    do i = 1, npoints

      read(iunit,*,end=500,err=500) x(i), y(i)

      x(i) = x(i) + 0d0                             ! get rid of -0d0
      y(i) = y(i) + 0d0 
    end do

    close(iunit)

    ! Check that coordinates are formatted  

    nswitch = 0
    dir1 = x(2) - x(1)
    do i = 3, npoints
      dir2 = x(i) - x(i-1)
      if (dir2 /= 0.d0) then
        if (dir2*dir1 < 0.d0) nswitch = nswitch + 1
        dir1 = dir2
      end if
    end do

    if (nswitch /= 1) then
    ! Open the file again only to avoid error at label 500.
      open(unit=iunit, file=filename, status='old')
    else
      return
    end if

    500 close(iunit)
    write (*,*)
    write (*,*)
    write(*,'(A)') "Incorrect format in "//trim(filename)//". File should"
    write(*,'(A)') "have x and y coordinates in 2 columns to form a single loop,"
    write(*,'(A)') "and there should be no blank lines.  See the user guide for"
    write(*,'(A)') "more information."
    call my_stop ("Processing stopped")

  end subroutine airfoil_read



  function te_gap (foil)

    !! trailing edge gap of foil 

    type(airfoil_type), intent(in)  :: foil
    double precision :: te_gap
  
    te_gap = sqrt ((foil%x(1) - foil%x(size(foil%x)))**2 + &
                   (foil%y(1) - foil%y(size(foil%y)))**2)
  end function 
  


  subroutine le_check (foil, ile_close, is_le)

    !! find the point index which is closest to the real splined le  
    !! If this point is EPSILON to le, is_le is .true. 

    use math_deps,      only : norm_2

    type (airfoil_type), intent(in) :: foil
    integer, intent(out)  :: ile_close
    logical, intent(out)  :: is_le

    integer :: i, npt
    double precision, allocatable :: x(:), y(:) 
    double precision, dimension(2) :: r1, r2
    double precision :: dist1, dist2, dot
    double precision :: xle, yle

    ile_close = 0
    is_le = .false.

    x = foil%X
    y = foil%y 
    npt = size(x)

    ! Get leading edge location from spline

    call le_find (foil, xle, yle)

    ! Determine leading edge index and where to add a point

    npt = size(x,1)
    do i = 1, npt-1
      r1(1) = xle - x(i)
      r1(2) = yle - y(i)
      dist1 = norm_2(r1)
      if (dist1 /= 0.d0) r1 = r1/dist1

      r2(1) = xle - x(i+1)
      r2(2) = yle - y(i+1)
      dist2 = norm_2(r2)
      if (dist2 /= 0.d0) r2 = r2/dist2

      dot = dot_product(r1, r2)
      if (dist1 < EPSILON) then                               ! point is defacto at 0,0 
        ile_close = i
        is_le = .true.
        exit
      else if (dist2 < EPSILON) then                          ! point is defacto at 0,0 
        ile_close = i+1
        is_le = .true.
        exit
      else if (dot < 0.d0) then
        if (dist1 < dist2) then
          ile_close = i
        else
          ile_close = i+1
        end if
        exit
      end if
    end do

  end subroutine 


  subroutine le_find (foil, xle, yle) 

    !----------------------------------------------------------------------------
    !! find real leading edge based on scalar product tangent and te vector = 0
    !! returns coordinates and arc length of this leading edge
    !----------------------------------------------------------------------------

    use spline,           only : eval_spline, spline_2D

    type (airfoil_type), intent(in)   :: foil 
    double precision, intent(out)     :: xle, yle

    double precision  :: sle

    sle = le_eval_spline (foil)
    call eval_spline (foil%spl, sLe,  xle,  yle, 0) 

  end subroutine  



  function le_eval_spline (foil) result (sle)

    !----------------------------------------------------------------------------
    !! find real leading edge based on scalar product tangent and te vector = 0
    !! returns arc length of this leading edge
    !----------------------------------------------------------------------------

    use spline,           only : eval_spline

    type (airfoil_type), intent(in)   :: foil 
    double precision                  :: sLe

    double precision                  :: x, y, dx, dy, ddx, ddy
    double precision                  :: dot, ddot
    double precision                  :: xTe, yTe, dxTe, dyTe, ds
    integer                           :: iter, iLeGuess

    double precision, parameter       :: EPS = 1d-10     ! Newton epsilon 

    ! sanity - is foil splined? 
    if (.not. allocated(foil%spl%s)) then 
      call my_stop ("Le_find: spline is not initialized")
    end if 

    ! first guess for uLe
    iLeGuess = minloc (foil%x, 1) 
    sLe      = foil%spl%s(iLeGuess)   
    
    ! te point 
    xTe = (foil%x(1) + foil%x(size(foil%x))) / 2d0 
    yTe = (foil%y(1) + foil%y(size(foil%y))) / 2d0 

    ! Newton iteration to get exact uLe

    do iter = 1, 50 

      sLe = min (sLe, 1.8d0)                            ! ensure to stay within boundaries 
      sLe = max (sLe, 0.2d0)
      
      call eval_spline (foil%spl, sLe,  x,  y, 0)       ! eval le coordinate and derivatives 
      call eval_spline (foil%spl, sLe, dx, dy, 1)       ! vector 1 tangent at le 
    
      dxTe = x - xTe                                    ! vector 2 from te to le 
      dyTe = y - yTe

      ! dot product of the two vectors                  ! f(u) --> 0.0  
      dot = dx * dxTe + dy * dyTe

      if ((abs(dot) < EPS)) exit                        ! succeeded

      ! df(u) for Newton 
      call eval_spline (foil%spl, sLe, ddx, ddy, 2)     ! get 2nd derivative 
      ddot = dx**2 + dy**2 + dxTe * ddx + dyTe * ddy    ! derivative of dot product 

      ds   = - dot / ddot                               ! Newton delta 
      sLe  = sLe + ds  

      ! print '(A,I5, 8F13.7)', "Newton", iter, dot, ddot, ds, sLe

    end do 


    if (((abs(dot) >= EPS))) then 

      call print_warning ("Le_find: Newton iteration not successful. Taking best guess" )
      sLe = foil%spl%s(iLeGuess) 

    end if 

  end function  


  function is_normalized_coord (foil) result(is_norm)

    !! Checks if foil is normalized - only looking at coordinates (no real LE check)
    !!  - Leading edge at 0,0 
    !!  - Trailing edge at 1,0 (upper and lower side may have a gap) 

    type(airfoil_type), intent(in)  :: foil
    logical       :: is_norm
    integer       :: x_min_at

    is_norm = .true. 

    ! Check TE 

    if (foil%x(1) /= 1d0 .or. foil%x(size(foil%x)) /= 1d0)    is_norm = .false.  
    if ((foil%y(1) + foil%y(size(foil%x))) /= 0d0)            is_norm = .false.

    ! Check LE 

    x_min_at = (minloc (foil%x,1))
    if (foil%x(x_min_at) /= 0d0)                              is_norm = .false.
    if (foil%y(x_min_at) /= 0d0)                              is_norm = .false.

  end function is_normalized_coord



  function is_normalized (foil, npan) result(is_norm)

    !! Checks if foil is normalized 
    !!  - Leading edge at 0,0 
    !!  - Trailing edge at 1,0 (upper and lower side may have a gap) 
    !!  - Number of panels equal npan  or npan + 1 (LE was added)

    use spline,     only: spline_2D

    type(airfoil_type), intent(in)  :: foil
    integer, intent(in)             :: npan

    type(airfoil_type)    :: foil_splined
    logical               :: is_norm, is_le
    integer               :: le

    is_norm = is_normalized_coord (foil)
    if (.not. is_norm) return 

    ! sanity check - spline is needed for find the real, splined LE

    foil_splined = foil                                     ! foil is just input

    if (.not. allocated(foil%spl%s)) then
      foil_splined%spl = spline_2d (foil%x, foil%y)
    end if 

    call le_check (foil_splined, le, is_le)
    if (.not. is_le) is_norm = .false.

    ! Check npan 

    if ((size(foil%x) /= npan) .and. & 
        (size(foil%x) /= npan + 1)) is_norm = .false.  

  end function is_normalized



  subroutine repanel_and_normalize (in_foil, panel_options, foil)

    !-----------------------------------------------------------------------------
    !! Repanel an airfoil with npoint and normalize it to get LE at 0,0 and
    !!    TE at 1.0 (upper and lower side may have a gap)  
    !-----------------------------------------------------------------------------

    use math_deps,    only : norm_2, norm2p
    use spline,       only : eval_spline, spline_2D

    type(airfoil_type), intent(in)          :: in_foil
    type(panel_options_type), intent(in)    :: panel_options
    type(airfoil_type), intent(out)         :: foil

    type(airfoil_type)  :: tmp_foil
    integer             :: i, n, ile_close
    logical             :: le_fixed, inserted, is_le
    double precision    :: xle, yle
    double precision, dimension(2) :: p_next, p, p_prev
    character (:), allocatable     :: text

    !
    ! For normalization le_find is used to calculate the (virtual) LE of
    !    the airfoil - then it's shifted, rotated, scaled to be normalized.
    !
    ! Bad thing: a subsequent le_find won't deliver LE at 0,0 but still with a little 
    !    offset. SO this is iterated until the offset is smaller than epsilon
    !

    tmp_foil = in_foil

    ! sanity - is foil splined? 
    if (.not. allocated(tmp_foil%spl%s)) then 
      tmp_foil%spl = spline_2D (tmp_foil%x, tmp_foil%y)
    end if 

    ! initial paneling to npoint_new
    call repanel (tmp_foil, panel_options, foil)

    le_fixed = .false. 
    inserted = .false.
  
    do i = 1,20

      call normalize (foil)

      ! repanel again to see if there is now a natural fir of splined LE

      tmp_foil = foil
      call repanel (tmp_foil, panel_options, foil)

      call le_find (foil, xle, yle)
      ! print '(A,2F12.8)', "le nach repan", xle, yle

      if (norm2p (xle, yle)  < EPSILON) then
        call normalize (foil)                   ! final normalize
        le_fixed = .true. 
        exit 
      end if
      
    end do

    ! reached a virtual LE which is closer to 0,0 than epsilon, set it to 0,0

    if (le_fixed) then 

      call le_check (foil, ile_close, is_le)

      if (.not. is_le) then 

        call print_warning ("Leading couldn't be iterated excactly to 0,0")
 
        ! ! is the LE panel of closest point much! shorter than the next panel? 
        ! !       if yes, take this point to LE 0,0
        ! p(1)      = foil%x(ile_close)
        ! p(2)      = foil%y(ile_close)
        ! p_next(1) = foil%x(ile_close + 1) - foil%x(ile_close)
        ! p_next(2) = foil%y(ile_close + 1) - foil%y(ile_close)
        ! p_prev(1) = foil%x(ile_close - 1) - foil%x(ile_close)
        ! p_prev(2) = foil%y(ile_close - 1) - foil%y(ile_close)
        ! if (((norm_2(p) / norm_2(p_next)) < LE_PANEL_FACTOR) .and. & 
        !     ((norm_2(p) / norm_2(p_prev)) < LE_PANEL_FACTOR)) then
        !   foil%x(ile_close) = 0d0
        !   foil%y(ile_close) = 0d0
        ! else

        !   ! add a new leading edge point at 0,0  
        !   call insert_point_at_00 (foil, inserted)

        ! end if 
      else

        ! point is already EPSILON at 0,0 - ensure 0,0 
        foil%x(ile_close) = 0d0                         
        foil%y(ile_close) = 0d0
      end if 
    else
      call print_warning ("Leading edge couln't be moved close to 0,0. Continuing ...",3)
      write (*,*)
    end if 

    ! te could be non zero due to numerical issues 

    n = size(foil%y)
    if (abs(foil%y(1)) < EPSILON_TE) then 
      foil%y(1) = 0d0                     ! make te gap to 0.0
      foil%y(n) = 0d0 
    else if ((foil%y(1) + foil%y(n)) < EPSILON_TE) then 
      foil%y(n) = - foil%y(1)             ! make te gap symmetrical
    end if 

    ! now split airfoil to get upper and lower sides for future needs  

    call split_foil_into_sides (foil)

    foil%name = in_foil%name // '-norm'

    text = 'Repaneling and normalizing.'
    if (inserted) text = text //' Added leading edge point.'
    text = text // ' Airfoil will have '
    call print_action (text, show_details, stri(foil%npoint) //' Points') 

  end subroutine repanel_and_normalize



  subroutine normalize (foil)

    !-----------------------------------------------------------------------------
    !! Translates and scales an airfoil such that it has a 
    !! - length of 1 
    !! - leading edge of spline is at 0,0 and trailing edge is symmetric at 1,x
    !-----------------------------------------------------------------------------

    use spline,       only : spline_2D

    type(airfoil_type), intent(inout) :: foil

    double precision :: foilscale_upper, foilscale_lower
    double precision :: angle, cosa, sina
    double precision :: xle, yle

    integer :: npoints, i, ile

    npoints = size(foil%x)

    ! sanity - is foil already splined? 

    if (.not. allocated(foil%spl%s)) then 
      foil%spl = spline_2D (foil%x, foil%y)      
    end if 

    ! get the 'real' leading edge of spline 

    call le_find (foil, xle, yle) 

    ! Translate so that the leading edge is at the origin

    do i = 1, npoints
      foil%x(i) = foil%x(i) - xle
      foil%y(i) = foil%y(i) - yle
    end do

    ! Rotate the airfoil so chord is on x-axis 

    angle = atan2 ((foil%y(1)+foil%y(npoints))/2.d0,(foil%x(1)+foil%x(npoints))/2.d0)
    cosa  = cos (-angle) 
    sina  = sin (-angle) 
    do i = 1, npoints
      foil%x(i) = foil%x(i) * cosa - foil%y(i) * sina
      foil%y(i) = foil%x(i) * sina + foil%y(i) * cosa
    end do

    ! Ensure TE is at x=1

    If (foil%x(1) /= 1d0) then 

      ! Scale airfoil so that it has a length of 1 
      ! - there are mal formed airfoils with different TE on upper and lower
      ! - also from rotation there is a mini diff  

      ile = minloc (foil%x, 1)
      foilscale_upper = 1.d0 / foil%x(1)
      do i = 1, ile  ! - 1
        foil%x(i) = foil%x(i)*foilscale_upper
        foil%y(i) = foil%y(i)*foilscale_upper
      end do

    end if 

    If (foil%x(npoints) /= 1d0) then 
      ile = minloc (foil%x, 1)
      foilscale_lower = 1.d0 / foil%x(npoints)
      do i = ile + 1, npoints
          foil%x(i) = foil%x(i)*foilscale_lower
          foil%y(i) = foil%y(i)*foilscale_lower
      end do
    end if 

    foil%x(1)       = 1d0                                   ! ensure now really, really
    foil%x(npoints) = 1d0

    ! Force TE to 0.0 if y < epsilon 

    if (abs(foil%y(1)) < EPSILON) then 
      foil%y(1) = 0.d0 
      foil%y(npoints) = 0.d0 
    end if 

    ! rebuild spline 

    foil%spl = spline_2D (foil%x, foil%y)      

  end subroutine normalize


  
  subroutine repanel (foil_in, panel_options, foil)

    !-----------------------------------------------------------------------------
    !! repanels airfoil to npoint
    !-----------------------------------------------------------------------------

    use spline,   only : eval_spline, spline_2D

    type(airfoil_type), intent(in)        :: foil_in
    type(panel_options_type), intent(in)  :: panel_options
    type(airfoil_type), intent(out)       :: foil

    integer                         :: nPanels, nPan_top, nPan_bot 
    double precision                :: s_start, s_end, s_le
    double precision, allocatable   :: u_cos_top (:), u_cos_bot(:), s(:), s_top(:), s_bot(:)
    double precision                :: le_bunch, te_bunch

    nPanels  = panel_options%npoint - 1
    le_bunch = panel_options%le_bunch
    te_bunch = panel_options%te_bunch

    ! in case of odd number of panels, top side will have +1 panels 
    if (mod(nPanels,2) == 0) then
        nPan_top = int (nPanels / 2)
        nPan_bot = nPan_top
    else 
        nPan_bot = int(nPanels / 2)
        nPan_top = nPan_bot + 1 
    end if 

    foil = foil_in

    ! major points on arc 

    s_start = foil%spl%s(1) 
    s_le    = le_eval_spline (foil) 
    s_end   = foil%spl%s(size(foil%spl%s))

    ! normalized point distribution u 

    u_cos_top = get_panel_distribution (nPan_top+1, le_bunch, te_bunch)
    u_cos_top = u_cos_top (size(u_cos_top) : 1 : -1)        ! flip
    s_top = s_start + abs (u_cos_top - 1d0) * s_le

    u_cos_bot = get_panel_distribution (nPan_bot+1, le_bunch, te_bunch)
    s_bot = s_le + u_cos_bot * (s_end - s_le) 

    ! add new top and bot distributions 

    s = [s_top, s_bot(2:)]  

    ! new calculated x,y coordinates  

    call eval_spline (foil%spl, s, foil%x, foil%y) 

    ! Finally re-spline with new coordinates 

    foil%npoint = panel_options%npoint
    foil%spl    = spline_2D (foil%x, foil%y) 

  end subroutine 



  function get_panel_distribution (nPoints, le_bunch, te_bunch) result (u) 

    !-----------------------------------------------------------------------------
    !! returns an array with cosinus similar distributed values 0..1
    !    
    ! Args: 
    ! nPoints : new number of coordinate points
    ! le_bunch : 0..1  where 1 is the full cosinus bunch at leading edge - 0 no bunch 
    ! te_bunch : 0..1  where 1 is the full cosinus bunch at trailing edge - 0 no bunch 
    !-----------------------------------------------------------------------------

    use math_deps,        only : linspace, diff_1D

    integer, intent(in)           :: npoints
    double precision, intent(in)  :: le_bunch, te_bunch

    double precision, allocatable :: u(:), beta(:), du(:)

    double precision      :: ufacStart, ufacEnd, pi, du_ip
    double precision      :: te_du_end, te_du_growth
    integer               :: ip

    pi = acos(-1.d0)

    ufacStart = 0.1d0 - le_bunch * 0.1d0
    ufacStart = max(0.0d0, ufacStart)
    ufacStart = min(0.5d0, ufacStart)
    ufacEnd   = 0.65d0  ! slightly more bunch      ! 0.25 = constant size towards te 

    beta = linspace (ufacStart, ufacEnd , nPoints) * pi
    u    = (1.0d0 - cos(beta)) * 0.5d0

    ! trailing edge area 

    te_du_end = 1d0 - te_bunch * 0.9d0              ! relative size of the last panel - smallest 0.1
    te_du_growth = 1.2d0                            ! growth rate going towars le 

    du = diff_1D(u)                                 ! the differences 
    
    ip = size(du)  
    du_ip = te_du_end * du(ip)                      ! size of the last panel  
    do while (du_ip < du(ip))                       ! run forward until size reaches normal size
        du(ip) = du_ip
        ip = ip - 1
        du_ip = du_ip * te_du_growth
    end do 

    ! rebuild u array and normalize to 0..1
    u  = 0d0
    do ip = 1, size(du) 
        u(ip+1) = u(ip) + du(ip) 
    end do 

    u = u / u (size(u))

    ! ensure 0.0 and 1.0 
    u(1)       = 0d0 
    u(size(u)) = 1d0 

  end function 



  subroutine repanel_bezier (foil_in, panel_options, foil)

    !-----------------------------------------------------------------------------
    !! repanels a bezier based airfoil to npoint
    !-----------------------------------------------------------------------------

    use shape_bezier,   only : bezier_eval_airfoil

    type(airfoil_type), intent(in)        :: foil_in
    type(panel_options_type), intent(in)  :: panel_options
    type(airfoil_type), intent(out)       :: foil

    foil = foil_in
    call bezier_eval_airfoil (foil%top_bezier, foil%bot_bezier, &
                              panel_options%npoint, foil%x, foil%y)
    call split_foil_into_sides (foil)

  end subroutine 




  subroutine insert_point_at_00 (foil, inserted)

    !! insert a new point at 0,0 being new leading edge  

    type(airfoil_type), intent(inout) :: foil
    logical, intent(out)              :: inserted
    double precision, allocatable     :: x_new(:), y_new(:)
    integer       :: i, j, npt 

    inserted = .false. 
    npt = size(foil%x) 

    allocate (x_new(npt+1))
    allocate (y_new(npt+1))

    j = 1

    do i = 1, npt
      if (foil%x(i) == 0d0 .and. foil%y(i) == 0d0) then     ! sanity check - there is already 0,0 
        return 
      else if (foil%y(i) > 0d0 .or. i < int(npt/4)) then 
        x_new(j) = foil%x(i)
        y_new(j) = foil%y(i)
        j = j + 1
      else
        x_new(j) = 0d0                                      ! insert new point at 0,0 
        y_new(j) = 0d0
        j = j + 1
        x_new(j) = foil%x(i)
        y_new(j) = foil%y(i)
        exit 
      end if 
    end do 

    ! copy the rest (bottom side)
    x_new(j+1:npt+1) = foil%x(i+1:npt)
    y_new(j+1:npt+1) = foil%y(i+1:npt)

    foil%x = x_new
    foil%y = y_new
    foil%npoint = size(foil%x)

    inserted = .true.

  end subroutine 



  subroutine split_foil_into_sides (foil)

    !-----------------------------------------------------------------------------
    !! Split an airfoil into its top and bottom side
    !! if there is already a leading edge at 0,0 
    !-----------------------------------------------------------------------------

    use spline,       only : spline_2d, eval_spline_curvature
 
    type(airfoil_type), intent(inout) :: foil
    double precision, allocatable     :: curv (:) 
    integer ile

    ile = minloc (foil%x, 1)
    if (ile == 0 .or. foil%x(ile) /= 0d0 .or. foil%y(ile) /= 0d0) then 
      call my_stop ("Split_foil: Leading edge isn't at 0,0")
    end if  

    !! build 2D spline 

    foil%spl = spline_2D (foil%x, foil%y)

    ! get curvature of complete surface

    curv = eval_spline_curvature (foil%spl, foil%spl%s) 
    
    ! split the polylines

    foil%top%name = 'Top'
    foil%top%x = foil%x(iLe:1:-1)
    foil%top%y = foil%y(iLe:1:-1)
    foil%top%curvature = curv(iLe:1:-1)

    foil%bot%name = 'Bot'

    if (.not. foil%symmetrical) then

      foil%bot%x = foil%x(iLe:)
      foil%bot%y = foil%y(iLe:)
      foil%bot%curvature = curv(iLe:)

    else                                     ! just sanity - it should already be symmetrical
      
      foil%bot%x =  foil%top%x
      foil%bot%y = -foil%top%y
      foil%bot%curvature = foil%top%curvature

    end if 

  end subroutine 



  subroutine rebuild_from_sides (top_side, bot_side, foil, name)

    !-----------------------------------------------------------------------------
    !! rebuild foil from a top and bot side - recalc curvature of top and bot 
    !! A new airfoil name can be set optionally 
    !-----------------------------------------------------------------------------

    use spline, only : spline_2D, eval_spline_curvature

    type(side_airfoil_type), intent(in)   :: top_side, bot_side
    type(airfoil_type), intent(inout)     :: foil
    character (*), optional, intent(in)   :: name

    double precision, allocatable         :: curv (:) 
    integer   :: pointst, pointsb

    pointst = size(top_side%x)
    pointsb = size(bot_side%x)
    foil%npoint = pointst + pointsb - 1

    if (allocated(foil%x)) deallocate(foil%x)
    if (allocated(foil%y)) deallocate(foil%y)
    allocate(foil%x(foil%npoint))
    allocate(foil%y(foil%npoint))

    foil%x(1:pointst) = top_side%x (pointst:1:-1)
    foil%y(1:pointst) = top_side%y (pointst:1:-1)

    foil%x(pointst:)  = bot_side%x 
    foil%y(pointst:)  = bot_side%y  

    foil%top  = top_side
    foil%top%name = 'Top'

    foil%bot  = bot_side  
    foil%bot%name = 'Bot'

    if (present(name)) then 
      foil%name = name 
    end if 
    
    ! rebuild spline, get curvature 
    foil%spl = spline_2D (foil%x, foil%y)
    curv = eval_spline_curvature (foil%spl, foil%spl%s)

    foil%top%curvature = curv(pointst:1:-1)
    foil%bot%curvature = curv(pointst:)

  end subroutine 


  
  subroutine make_symmetrical (foil)

    !-----------------------------------------------------------------------------
    !! mirrors top side to bot to make foil symmetrical
    !-----------------------------------------------------------------------------

    type(airfoil_type), intent(inout) :: foil
    integer ile

    call print_note ("Mirroring top half of seed airfoil for symmetrical constraint.")

    ile = minloc (foil%x, 1)
    if (ile == 0 .or. foil%x(ile) /= 0d0 .or. foil%y(ile) /= 0d0) then 
      call my_stop ("make_symmetrical: Leading edge isn't at 0,0")
    end if  

    foil%bot%x =  foil%top%x
    foil%bot%y = -foil%top%y
    foil%symmetrical = .true.

    call rebuild_from_sides (foil%top, foil%bot, foil)

    if (foil%is_bezier_based) then
      foil%bot_bezier%px =  foil%top_bezier%px 
      foil%bot_bezier%py = -foil%top_bezier%py
    end if 

  end subroutine 



  subroutine airfoil_write(filename, name, foil)
     
    !! Writes an airfoil to a labeled file
    
    character(*), intent(in) :: filename, name
    type(airfoil_type), intent(in) :: foil
    integer :: iunit, ioerr
    character(len=512) :: msg

    ! Open file for writing and out ...

    iunit = 13
    open  (unit=iunit, file=filename, status='replace',  iostat=ioerr, iomsg=msg)
    if (ioerr /= 0) then 
      call my_stop ("Unable to write to file '"//trim(filename)//"': "//trim(msg))
    end if 

    call print_action ("Writing airfoil to", show_details, filename)

    call airfoil_write_to_unit (iunit, name, foil)
    close (iunit)

  end subroutine airfoil_write


  subroutine airfoil_write_with_shapes (foil)

    !-----------------------------------------------------------------------------
    !! write airfoil .dat and bezier or hicks henne files 
    !-----------------------------------------------------------------------------

    use shape_bezier,       only : write_bezier_file
    use shape_hicks_henne,  only : write_hh_file
 
    type (airfoil_type), intent(in) :: foil 

    character (:), allocatable      :: output_file 

    output_file = foil%name//'.dat'
    call airfoil_write (output_file, foil%name, foil)
  
    if (foil%is_bezier_based) then
      output_file = foil%name//'.bez'

      call print_action ('Writing Bezier  to', show_details, output_file)

      call write_bezier_file (output_file, foil%name, foil%top_bezier, foil%bot_bezier)
  
    else if (foil%is_hh_based) then
      output_file = foil%name//'.hicks'

      call print_action ('Writing Hicks-Henne to', show_details, output_file)

      call write_hh_file (output_file, foil%hh_seed_name, foil%top_hh, foil%bot_hh)

    end if 
  
  end subroutine 



  subroutine airfoil_write_to_unit (iunit, title, foil)

    !! Writes an airfoil with a title to iunit
    !    --> central function for all foil coordinate writes

    integer, intent(in)             :: iunit
    character(*), intent(in)        :: title
    type(airfoil_type), intent(in)  :: foil
    integer :: i

    ! Write label to file
    
    write(iunit,'(A)') trim(title)

    ! Write coordinates

    do i = 1, size(foil%x)
      write(iunit,'(2F12.7)')         foil%x(i), foil%y(i)
    end do

  end subroutine airfoil_write_to_unit



  subroutine print_coordinate_data (foil1, foil2, foil3, indent)

    !-----------------------------------------------------------------------------
    !! prints geometry data like le position, te, etc of up to 3 airfoils 
    !-----------------------------------------------------------------------------

    type (airfoil_type), intent(in)           :: foil1
    type (airfoil_type), intent(in), optional :: foil2, foil3
    integer, intent(in), optional             :: indent
    
    integer                           :: nfoils, ile, i, ind
    type (airfoil_type)               :: foils (3) 
    character (20)                    :: name
    double precision                  :: xle_s, yle_s

    nfoils = 1
    foils(1) = foil1
    if (present (foil2)) then
      nfoils = 2
      foils(2) = foil2
    end if 
    if (present (foil3)) then 
      nfoils = 3
      foils(3) = foil3
    end if 

    ind = 5
    if (present (indent)) then 
      if (indent >= 0 .and. indent < 80) ind = indent
    end if

    ! print header 
    
    call print_fixed     (""       ,ind, .false.)   
    call print_fixed     ("Name"    ,15, .false.)   
    call print_fixed     ("np"      , 5, .true.)   
    call print_fixed     ("ilE"     , 5, .true.)   

    call print_fixed     ("xLE"     ,13, .true.)   
    call print_fixed     ("yLE"     ,11, .true.)   
    call print_fixed     ("spl xLE" ,11, .true.)   
    call print_fixed     ("spl yLE" ,11, .true.)   

    call print_fixed     ("top xTE" ,13, .true.)   
    call print_fixed     ("top yLE" ,11, .true.)   
    call print_fixed     ("bot xLE" ,11, .true.)   
    call print_fixed     ("bot yLE" ,11, .true.)   
    print *

    ! print data 
    do i = 1, nfoils 

      ile = minloc (foils(i)%x,1)
      name = foils(i)%name 
      call le_find (foils(i), xle_s, yle_s)

      if (abs(xle_s) < 0.0000001d0) xle_s = 0d0
      if (abs(yle_s) < 0.0000001d0) yle_s = 0d0

      call print_fixed     (""        ,ind, .false.)   
      call print_fixed     (foils(i)%name, 15, .false.)   
      call print_colored_i (5, Q_NO, foils(i)%npoint)
      call print_colored_i (5, Q_NO, ile) 

      call print_colored_r (13, '(F10.7)', Q_NO, foils(i)%x(ile))
      call print_colored_r (11, '(F10.7)', Q_NO, foils(i)%y(ile))
      call print_colored_r (11, '(F10.7)', Q_NO, xle_s)
      call print_colored_r (11, '(F10.7)', Q_NO, yle_s)

      call print_colored_r (13, '(F10.7)', Q_NO, foils(i)%x(1))
      call print_colored_r (11, '(F10.7)', Q_NO, foils(i)%y(1))
      call print_colored_r (11, '(F10.7)', Q_NO, foils(i)%x(foils(i)%npoint))
      call print_colored_r (11, '(F10.7)', Q_NO, foils(i)%y(foils(i)%npoint))
      print * 

    end do 


  end subroutine
end module airfoil_operations