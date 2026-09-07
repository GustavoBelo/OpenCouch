Name:           open-couch
Version:        2.0.0
Release:        1%{?dist}
Summary:        Console mode for your Linux desktop

License:        GPL-3.0-or-later
URL:            https://github.com/GustavoBelo/OpenCouch
Source0:        %{url}/archive/refs/tags/v%{version}.tar.gz#/%{name}-%{version}.tar.gz

BuildRequires:  golang >= 1.26
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  gcc-c++
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
BuildRequires:  qt6-qttools-devel
BuildRequires:  libappstream-glib

Requires:       %{name}-engine = %{version}-%{release}
Requires:       qt6-qtbase
Requires:       qt6-qtdeclarative
Requires:       qt6-qtwayland

%description
Open Couch hands the whole machine to Steam's gamescope session on the
television and gives it back cleanly when you leave. This package is the
graphical application; everything it does can also be done from the command
line with open-couch-engine, which it requires.

# The engine is split out because the two halves have opposite needs: it is a
# static binary with no runtime dependencies, while the window pulls in the
# whole Qt Quick runtime. A machine in the living room should not have to
# install Qt to be a console.
%package engine
Summary:        The Open Couch console-mode engine
# gamescope-session is deliberately not required: the package providing it
# differs on every distribution, and `open-couch-engine doctor` reports a
# missing one far better than a dependency failure would.
Requires:       gamescope
Requires:       systemd
Requires:       pulseaudio-utils

%description engine
The engine that hosts your desktop and Steam's gamescope session in one login
session, switches between them, and puts the sound and the display back on the
way home. A static binary with no runtime dependencies; it does everything from
the command line and does not need the graphical application.

%prep
%autosetup -n OpenCouch-%{version}

%build
# Static on purpose: the engine runs as the login session itself, before much of
# the system is up, and has no business depending on shared libraries it might
# not find there.
pushd engine
CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.version=%{version}" \
    -o %{_builddir}/open-couch-engine \
    ./cmd/open-couch-engine
popd

%cmake -S app -B %{_vpath_builddir} -G Ninja -DCMAKE_INSTALL_PREFIX=%{_prefix}
%cmake_build

%check
pushd engine
go test ./...
popd

%install
%cmake_install

# The CMake build produces the engine because the application needs one to run
# against; the copy that ships is the one built above, so the two subpackages
# cannot disagree about which binary is installed.
install -Dm755 %{_builddir}/open-couch-engine %{buildroot}%{_bindir}/open-couch-engine

%files
%license LICENSE
%doc README.md
%{_bindir}/opencouch
%{_datadir}/applications/io.github.gustavobelo.opencouch.desktop
%{_datadir}/icons/hicolor/*/apps/io.github.gustavobelo.opencouch.png
%{_metainfodir}/io.github.gustavobelo.opencouch.metainfo.xml

%files engine
%license LICENSE
%{_bindir}/open-couch-engine
# The hosting session entry. Installing it for every account is what removes the
# one step of setup that needed root: the engine is on PATH for all of them, so
# one entry serves all of them.
%{_datadir}/wayland-sessions/open-couch-session.desktop

%changelog
* Fri Sep 04 2026 Gustavo Belo <gustavobelo28@gmail.com> - 2.0.0-1
- Console mode: hands the machine to Steam's gamescope session and back
