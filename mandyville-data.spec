Name:       mandyville-data
Version:    0.1
Release:    1%{?dist}
Summary:    Data fetching and data storage for mandyville.

License:    MIT
URL:        https://github.com/sirgraystar/mandyville-data
Source0:    %{name}-%{version}-%{release}.tar.gz

Requires:    perl(Capture::Tiny)
Requires:    perl(Const::Fast)
Requires:    perl(Dir::Self)
Requires:    perl(DBD::Pg)
Requires:    perl(DBI)
Requires:    perl(File::Temp)
Requires:    perl(SQL::Abstract::More)
Requires:    perl(YAML::XS)

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

# Libraries
install -dm755 %{buildroot}%{perl_vendorlib}/Mandyville/
cp -a lib/Mandyville/* %{buildroot}%{perl_vendorlib}/Mandyville/

%files
%defattr(-,root,root,-)

# Binaries
%{_bindir}/update-competition-data

# Libraries
%{perl_vendorlib}/Mandyville/*.pm
%{perl_vendorlib}/Mandyville/API/*.pm

# Config
%config(noreplace) %{_sysconfdir}/mandyville/config.yaml

%clean
rm -rf $RPM_BUILD_ROOT

%changelog
* Sat Mar 13 2021 Owen Davies <owen@odavi.es> - 0.0.1-1
- Initial package
