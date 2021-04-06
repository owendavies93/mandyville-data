Name:       mandyville-data
Version:    0.1
Release:    9%{?dist}
Summary:    Data fetching and data storage for mandyville.

License:    MIT
URL:        https://github.com/sirgraystar/mandyville-data
Source0:    %{name}-%{version}-%{release}.tar.gz

Requires:   moreutils
Requires:   perl(Array::Utils)
Requires:   perl(Capture::Tiny)
Requires:   perl(Const::Fast)
Requires:   perl(Cpanel::JSON::XS)
Requires:   perl(Date::Time)
Requires:   perl(Dir::Self)
Requires:   perl(DBD::Pg)
Requires:   perl(DBI)
Requires:   perl(File::Temp)
Requires:   perl(Mojo::Base)
Requires:   perl(SQL::Abstract::More)
Requires:   perl(YAML::XS)

%description
Data fetching and data storage for mandyville.

%prep
%setup -q -n data

%install
# Scripts
install -dm755 %{buildroot}%{_bindir}/
install -Dm755 bin/* %{buildroot}%{_bindir}/

# Config
install -dm755 %{buildroot}%{_sysconfdir}/mandyville/
install -Dm644 etc/mandyville/* %{buildroot}%{_sysconfdir}/mandyville/
install -dm755 %{buildroot}%{_sysconfdir}/cron.d/
install -Dm644 etc/cron.d/* %{buildroot}%{_sysconfdir}/cron.d/

# Libraries
install -dm755 %{buildroot}%{perl_vendorlib}/Mandyville/
cp -a lib/Mandyville/* %{buildroot}%{perl_vendorlib}/Mandyville/

%files
%defattr(-,root,root,-)

# Binaries
%{_bindir}/send-healthcheck
%{_bindir}/update-competition-data
%{_bindir}/update-fixture-data
%{_bindir}/update-fpl-info
%{_bindir}/update-understat-ids
%{_bindir}/update-understat-info

# Crons
%{_sysconfdir}/cron.d/update-competition-data
%{_sysconfdir}/cron.d/update-fixture-data
%{_sysconfdir}/cron.d/update-understat-info

# Libraries
%{perl_vendorlib}/Mandyville/*.pm
%{perl_vendorlib}/Mandyville/API/*.pm

# Config
%config(noreplace) %{_sysconfdir}/mandyville/config.yaml

%clean
rm -rf $RPM_BUILD_ROOT

%changelog
* Sun Apr 04 2021 Owen Davies <owen@odavi.es> - 0.0.1-9
- Fetch and store fixture data
- Add gameweek processing

* Thu Apr 01 2021 Owen Davies <owen@odavi.es> - 0.0.1-7
- Add update-understat-info

* Wed Mar 31 2021 Owen Davies <owen@odavi.es> - 0.0.1-6
- Correctly redirect cron output; don't overwrite log files

* Tue Mar 30 2021 Owen Davies <owen@odavi.es> - 0.0.1-5
- Add missing Mojo::Base dependancy

* Sun Mar 28 2021 Owen Davies <owen@odavi.es> - 0.0.1-4
- Escape percentage signs in crons

* Sat Mar 27 2021 Owen Davies <owen@odavi.es> - 0.0.1-3
- Add script to fetch understat IDs

* Thu Mar 25 2021 Owen Davies <owen@odavi.es> - 0.0.1-2
- Add health checking for crons

* Sat Mar 13 2021 Owen Davies <owen@odavi.es> - 0.0.1-1
- Initial package
