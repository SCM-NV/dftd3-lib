module libdftd3_module
  use dftd3_module
  use copyc6_module
  use param_module
  implicit none
  private

  public :: dftd3_input, dftd3
  public :: dftd3_init, dftd3_set_params, dftd3_set_functional
  public :: dftd3_dispersion, dftd3_pbc_dispersion
  public :: get_atomic_number

  public :: max_elem, maxc
  public :: printoptions, stoprun, readl, rdatomnumber, pbcrdatomnumber
  public :: rdcoord, pbcrdcoord, rdpar, pbcwregrad, outg
  
  integer, parameter :: wp = kind(1.0d0)


  type :: dftd3_input
    ! Whether three body term should be calculated
    logical :: threebody

    ! Numerical gradients instead of analytical ones
    logical :: numgrad

    ! C6 min flags (or unallocated if not needed)
    logical, allocatable :: minc6list(:)

    ! C6 max flags (or unallocated if not needed)
    logical, allocatable :: maxc6list(:)
    
    ! Real space cutoff
    real(wp) :: cutoff

    ! Real space cutoff for coordination numbers
    real(wp) :: cutoff_cn
  end type dftd3_input


  type :: dftd3
    logical :: noabc, numgrad
    integer :: version
    real(wp) :: s6, rs6, s18, rs18, alp
    real(wp) :: rthr, cn_thr
    integer  :: rep_vdw(3), rep_cn(3)
    real(wp), allocatable :: r0ab(:,:), c6ab(:,:,:,:,:)
    integer, allocatable :: mxc(:)
  end type dftd3
    

contains

  subroutine dftd3_init(this, input)
    type(dftd3), intent(out) :: this
    type(dftd3_input), intent(in) :: input

    logical, allocatable :: minc6list(:), maxc6list(:)
    logical :: minc6, maxc6

    this%noabc = .not. input%threebody
    this%numgrad = input%numgrad

    allocate(minc6list(max_elem))
    if (allocated(input%minc6list)) then
      minc6list(:) = input%minc6list
    else
      minc6list(:) = .false.
    end if

    minc6 = any(minc6list)
    allocate(maxc6list(max_elem))
    if (allocated(input%maxc6list)) then
      maxc6list(:) = input%maxc6list
    else
      maxc6list(:) = .false.
    end if
    maxc6 = any(maxc6list)
    
    allocate(this%c6ab(max_elem, max_elem, maxc, maxc, 3))
    allocate(this%mxc(max_elem))
    call copyc6("", maxc, max_elem, this%c6ab, this%mxc, minc6, minc6list, &
        & maxc6, maxc6list)
    this%rthr = input%cutoff**2
    this%cn_thr = input%cutoff_cn**2
    allocate(this%r0ab(max_elem, max_elem))
    call setr0ab(max_elem, autoang, this%r0ab)

  end subroutine dftd3_init
    
    
  subroutine dftd3_set_functional(this, func, version, tz)
    type(dftd3), intent(inout) :: this
    character(*), intent(in) :: func
    integer, intent(in) :: version
    logical, intent(in) :: tz

    this%version = version
    call setfuncpar(func, this%version, tz, this%s6, this%rs6, this%s18, &
        & this%rs18, this%alp)
    
  end subroutine dftd3_set_functional


  subroutine dftd3_set_params(this, pars, version)
    type(dftd3), intent(inout) :: this
    real(wp), intent(in) :: pars(:)
    integer, intent(in) :: version

    if (size(pars) /= 5) then
      write(*,*) 'Invalid number of custom parameters'
      stop 1
    end if

    this%s6 = pars(1)
    this%rs6 = pars(2)
    this%s18 = pars(3)
    this%rs18 = pars(4)
    this%alp = pars(5)
    this%version = version
    
  end subroutine dftd3_set_params


  subroutine dftd3_dispersion(this, coords, izp, disp, grads)
    type(dftd3), intent(in) :: this
    real(wp), intent(in) :: coords(:,:)
    integer, intent(in) :: izp(:)
    real(wp), intent(out) :: disp
    real(wp), optional, intent(out) :: grads(:,:)

    logical, allocatable :: fix(:)
    integer :: natom
    real(wp) :: s6, s18, rs6, rs8, rs10, alp6, alp8, alp10
    real(wp) :: e6, e8, e10, e12, e6abc, gdsp, gnorm

    natom = size(coords, dim=2)
    s6 = this%s6
    s18 = this%s18
    rs6 = this%rs6
    rs8 = this%rs18
    rs10 = this%rs18
    alp6 = this%alp
    alp8 = alp6 + 2.0_wp
    alp10 = alp8 + 2.0_wp
    call edisp(max_elem, maxc, natom, coords, izp, this%c6ab, this%mxc, &
        & r2r4, this%r0ab, rcov, rs6, rs8, rs10, alp6, alp8, alp10, &
        & this%version, this%noabc, this%rthr, this%cn_thr, e6, e8, e10, e12, &
        & e6abc)
    disp = -e6 * this%s6 - e8 * this%s18 - e6abc

    if (.not. present(grads)) then
      return
    end if

    allocate(fix(natom))
    fix(:) = .false.
    call gdisp(max_elem, maxc, natom, coords, izp, this%c6ab, this%mxc, r2r4, &
        & this%r0ab, rcov, s6, s18, rs6, rs8, rs10, alp6, alp8, alp10, &
        & this%noabc, this%rthr, this%numgrad, this%version, .false., grads, &
        & gdsp, gnorm, this%cn_thr, fix)
    
  end subroutine dftd3_dispersion


  subroutine dftd3_pbc_dispersion(this, coords, izp, latvecs, disp, grads, &
      & stress)
    type(dftd3), intent(in) :: this
    real(wp), intent(in) :: coords(:,:)
    integer, intent(in) :: izp(:)
    real(wp), intent(in) :: latvecs(:,:)
    real(wp), intent(out) :: disp
    real(wp), optional, intent(out) :: grads(:,:), stress(:,:)

    integer :: natom
    real(wp) :: s6, s18, rs6, rs8, rs10, alp6, alp8, alp10
    real(wp) :: e6, e8, e10, e12, e6abc, gnorm, disp2
    real(wp) :: rtmp3(3)
    integer :: rep_cn(3), rep_vdw(3)

    if (present(grads) .neqv. present(stress)) then
      write(*,*) "!!! Error in dftd3_pbc_dispersion"
      write(*,*) "Either both grads and stress must be present or none of them"
      stop
    end if

    natom = size(coords, dim=2)
    s6 = this%s6
    s18 = this%s18
    rs6 = this%rs6
    rs8 = this%rs18
    rs10 = this%rs18
    alp6 = this%alp
    alp8 = alp6 + 2.0_wp
    alp10 = alp8 + 2.0_wp

    call set_criteria(this%rthr, latvecs, rtmp3)
    rep_vdw(:) = int(rtmp3) + 1
    call set_criteria(this%cn_thr, latvecs, rtmp3)
    rep_cn(:) = int(rtmp3) + 1
    call pbcedisp(max_elem, maxc, natom, coords, izp, this%c6ab, this%mxc, &
        & r2r4, this%r0ab, rcov, rs6, rs8, rs10, alp6, alp8, alp10, &
        & this%version, this%noabc, e6, e8, e10, e12, e6abc, latvecs, &
        & this%rthr, rep_vdw, this%cn_thr, rep_cn)
    disp = -e6 * this%s6 - e8 * this%s18 - e6abc

    if (.not. present(grads)) then
      return
    end if

    grads(:,:) = 0.0_wp
    call pbcgdisp(max_elem, maxc, natom, coords, izp, this%c6ab, this%mxc, &
        & r2r4, this%r0ab, rcov, s6, s18, rs6, rs8, rs10, alp6, alp8, alp10, &
        & this%noabc, this%numgrad, this%version, grads, disp2, gnorm, &
        & stress, latvecs, rep_vdw, rep_cn, this%rthr, .false., this%cn_thr)
    
  end subroutine dftd3_pbc_dispersion


  function get_atomic_number(species) result(izp)
    character(*), intent(in) :: species
    integer :: izp

    call elem(trim(species), izp)

  end function get_atomic_number


end module libdftd3_module
