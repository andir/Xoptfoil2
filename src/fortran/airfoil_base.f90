! MIT License
! Copyright (C) 2017-2019 Daniel Prosser
! Copyright (c) 2024 Jochen Guenzel

module airfoil_base

  ! Airfoil type and basic operations 

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
    character(:), allocatable     :: name             ! either 'Top' or 'Bot' or 'Thickness' ...
    double precision, allocatable :: x(:)
    double precision, allocatable :: y(:)
    double precision, allocatable :: curvature(:)
  end type 

  ! the airfoil type

  type airfoil_type 

    character(:), allocatable     :: name               ! name of the airfoil
    double precision, allocatable :: x(:)               ! airfoil coordinates
    double precision, allocatable :: y(:)
    logical :: symmetrical    = .false.                  ! airfoil symmetrical? -> bot equals top side

    type (side_airfoil_type)      :: top                 ! top side of airfoil
    type (side_airfoil_type)      :: bot                 ! bottom side of airfoil 

    type (spline_2D_type)         :: spl                 ! cubic spline of coordinates 

    logical :: is_bezier_based = .false.                 ! was airfoil generated by bezier curve
    type (bezier_spec_type)       :: top_bezier          ! bezier curve specification if 'bezier_based'
    type (bezier_spec_type)       :: bot_bezier          ! bezier curve specification if 'bezier_based'

    logical :: is_hh_based = .false.                     ! was airfoil generated by hicks henne functions
    character (:), allocatable    :: hh_seed_name        ! name of seed airfoil hh are applied on 
    double precision, allocatable :: hh_seed_x(:)        ! seed coordinates for rebuild (write)  
    double precision, allocatable :: hh_seed_y(:)              
    type (hh_spec_type)           :: top_hh              ! hh specs for top side 
    type (hh_spec_type)           :: bot_hh              ! hh specs for bot side 
 
  end type airfoil_type


  type panel_options_type   
    integer          :: npoint                  ! number of coordinate points 
    double precision :: le_bunch                ! panel bunching at le 0..1
    double precision :: te_bunch                ! panel bunching at te 0..1
  end type 

  public :: panel_options_type
  public :: side_airfoil_type
  public :: airfoil_type

  ! --- public functions ------------------------------------------------------------

  public :: airfoil_load
  public :: airfoil_write, airfoil_write_with_shapes
  public :: is_dat_file
  public :: print_airfoil_write
  public :: build_from_sides
  public :: split_foil_into_sides 
  public :: is_normalized_coord
  public :: make_symmetrical
  public :: airfoil_name_flapped

contains

  subroutine airfoil_load (filename, foil)

    !----------------------------------------------------------------------------
    !! Reads an airfoil from a file (checks ordering)
    !----------------------------------------------------------------------------

    character(*), intent(in) :: filename
    type(airfoil_type), intent(out) :: foil

    logical :: labeled
    integer :: i, np
    double precision, allocatable   :: xtemp(:), ytemp(:)

    if (trim(filename) == '') then
      call my_stop ('No airfoil file defined either in input file nor as command line argument')
    end if 

    ! Read number of points and allocate coordinates

    call airfoil_points(filename, np, labeled)

    allocate(foil%x(np))
    allocate(foil%y(np))

    ! Read airfoil from file

    call airfoil_read(filename, np, labeled, foil%name, foil%x, foil%y)

    ! Change point ordering to counterclockwise, if necessary

    if (foil%y(np) > foil%y(1)) then
      
      call print_warning ('Changing point ordering to counter-clockwise ...')
      
      xtemp = foil%x
      ytemp = foil%y
      do i = 1, np
        foil%x(i) = xtemp (np-i+1)
        foil%y(i) = ytemp (np-i+1)
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



  function is_dat_file (filename)

    !! .true. if filename has ending '.dat'

    character(*),  intent(in) :: filename
    logical                   :: is_dat_file 
    character(:), allocatable :: suffix 
    
    suffix = filename_suffix (filename)
    is_dat_file = suffix == '.dat' .or. suffix =='.DAT'

  end function  




  function is_normalized_coord (foil) result(is_norm)

    !! Checks if foil is normalized - only looking at coordinates (no real LE check)
    !!  - Leading edge at 0,0 
    !!  - Trailing edge at 1,0 (upper and lower side may have a gap) 

    type(airfoil_type), intent(in)  :: foil
    logical       :: is_norm
    integer       :: ile

    is_norm = .true. 

    ! Check TE 

    if (foil%x(1) /= 1d0 .or. foil%x(size(foil%x)) /= 1d0)    is_norm = .false.  
    if ((foil%y(1) + foil%y(size(foil%x))) /= 0d0)            is_norm = .false.

    ! Check LE 

    ile = (minloc (foil%x,1))
    if (foil%x(ile) /= 0d0)                                   is_norm = .false.
    if (foil%y(ile) /= 0d0)                                   is_norm = .false.

  end function is_normalized_coord




  subroutine split_foil_into_sides (foil)

    !-----------------------------------------------------------------------------
    !! Split an airfoil into its top and bottom side
    !! if there is already a leading edge at 0,0 
    !-----------------------------------------------------------------------------

    use spline,       only : spline_2d, eval_spline_curvature
 
    type(airfoil_type), intent(inout) :: foil
    double precision, allocatable     :: curv (:) 
    integer ile

    if (.not. is_normalized_coord (foil)) then 
        call my_stop ("split_foil: Leading edge isn't at 0,0")
    end if  

    !! build 2D spline 

    foil%spl = spline_2D (foil%x, foil%y)

    ! get curvature of complete surface

    curv = eval_spline_curvature (foil%spl, foil%spl%s) 
    
    ! split the polylines

    ile = minloc (foil%x, 1)

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



  subroutine build_from_sides (foil)

    !-----------------------------------------------------------------------------
    !! rebuild foil from its current top and bot side - recalc curvature of top and bot 
    !-----------------------------------------------------------------------------

    use spline, only : spline_2D, eval_spline_curvature

    type(airfoil_type), intent(inout)     :: foil

    double precision, allocatable         :: curv (:) 
    integer   :: npt, npb, np

    npt = size(foil%top%x)
    npb = size(foil%bot%x)
    np      = npt + npb - 1

    if (allocated(foil%x)) deallocate(foil%x)
    if (allocated(foil%y)) deallocate(foil%y)
    allocate(foil%x(np))
    allocate(foil%y(np))

    foil%x(1:npt) = foil%top%x (npt:1:-1)
    foil%y(1:npt) = foil%top%y (npt:1:-1)

    foil%x(npt:)  = foil%bot%x 
    foil%y(npt:)  = foil%bot%y  

    foil%top%name = 'Top'
    foil%bot%name = 'Bot'
   
    ! rebuild spline, get curvature 

    foil%spl = spline_2D (foil%x, foil%y)
    curv = eval_spline_curvature (foil%spl, foil%spl%s)

    foil%top%curvature = curv(npt:1:-1)
    foil%bot%curvature = curv(npt:)

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

    call build_from_sides (foil)

    if (foil%is_bezier_based) then
      foil%bot_bezier%px =  foil%top_bezier%px 
      foil%bot_bezier%py = -foil%top_bezier%py
    end if 

  end subroutine 



  subroutine airfoil_write (pathFileName, foil)
     
    !-----------------------------------------------------------------------------
    !! Writes an airfoil to a labeled file
    !-----------------------------------------------------------------------------
    
    character(*), intent(in)        :: pathFileName
    type(airfoil_type), intent(in)  :: foil

    integer                         :: iunit, ioerr, i
    character(len=512)              :: msg

    ! Open file for writing and out ...

    iunit = 13
    open  (unit=iunit, file=pathFileName, status='replace',  iostat=ioerr, iomsg=msg)
    if (ioerr /= 0) then 
      call my_stop ("Unable to write to file '"//trim(pathFileName)//"': "//trim(msg))
    end if 

    write(iunit,'(A)') trim(foil%name)

    ! Write coordinates

    do i = 1, size(foil%x)
      write(iunit,'(2F12.7)') foil%x(i), foil%y(i)
    end do

    close (iunit)

  end subroutine 



  subroutine print_airfoil_write (dir, fileName, file_type, highlight)
     
    !-----------------------------------------------------------------------------
    !! print user message about writing an airfoil 
    !! If 'highlight' the airfoil name will be highlighted
    !-----------------------------------------------------------------------------
    
    character(*), intent(in)        :: dir, fileName, file_type
    logical, intent(in), optional   :: highlight 

    logical                         :: do_highlight

    if (present(highlight)) then 
      do_highlight = highlight 
    else 
      do_highlight = .true. 
    end if 

    if (.not. show_details .and. .not. do_highlight) return 


    if (file_type == "bez") then 
      call print_action ("Writing bezier      ", no_crlf = .true.)
    else if (file_type == "hicks") then 
      call print_action ("Writing hicks-henne ", no_crlf = .true.)
    else
      call print_action ("Writing airfoil     ", no_crlf = .true.)
    end if 


    if (do_highlight) then 
      call print_colored (COLOR_NORMAL, fileName)
    else 
      call print_colored (COLOR_NOTE,   fileName)
    end if 

    if (dir == "") then 
      print * 
    else 
      call print_text ("to "//dir)
    end if  


  end subroutine 



  subroutine airfoil_write_with_shapes (foil, output_dir, highlight)

    !-----------------------------------------------------------------------------
    !! write airfoil .dat and bezier or hicks henne files 
    !! optional print airfoil name highlighted (default) 
    !-----------------------------------------------------------------------------

    use shape_bezier,       only : write_bezier_file
    use shape_hicks_henne,  only : write_hh_file
 
    type (airfoil_type), intent(in) :: foil 
    character (*), intent(in)       :: output_dir 
    logical, intent(in), optional   :: highlight 

    character (:), allocatable      :: fileName 
    logical                         :: do_highlight

    if (present(highlight)) then 
      do_highlight = highlight 
    else 
      do_highlight = .true. 
    end if 

    ! write normal .dat 

    fileName = foil%name//'.dat'

    call print_airfoil_write (output_dir, fileName, 'dat', highlight=do_highlight)

    call airfoil_write (path_join (output_dir, fileName), foil)

    
    ! write bezier .bez 

    if (foil%is_bezier_based) then

      fileName = foil%name//'.bez'
      call print_airfoil_write (output_dir, fileName, 'bez', highlight=do_highlight)

      call write_bezier_file (path_join (output_dir, fileName), foil%name, foil%top_bezier, foil%bot_bezier)


    ! write hicks-henne .hicks 

    else if (foil%is_hh_based) then

      fileName = foil%name//'.hicks'
      call print_airfoil_write (output_dir, fileName, 'hicks', highlight=do_highlight)
  
      call write_hh_file (path_join (output_dir, fileName), foil%name, foil%top_hh, foil%bot_hh, &
                          foil%hh_seed_name, foil%hh_seed_x, foil%hh_seed_y)

    end if 
  
  end subroutine 



  function airfoil_name_flapped (foil, angle) result (flapped_name) 
     
    !-----------------------------------------------------------------------------
    !! returns name of airfoil being flapped with angle (in degrees)
    !-----------------------------------------------------------------------------
    
    type(airfoil_type), intent(in)  :: foil
    double precision, intent(in)    :: angle 
    character(:), allocatable       :: flapped_name
    character (20)                  :: text_degrees

    if (angle == 0) then 
      flapped_name = foil%name
    else

      if (int(angle)*10  == int(angle*10d0)) then       !degree having decimal?
        write (text_degrees,'(SP,I3)') int (angle)
      else
        write (text_degrees,'(SP,F6.1)') angle
      end if
      flapped_name = foil%name // '_f' // trim(adjustl(text_degrees))

    end if 

  end function 

end module