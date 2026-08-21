Name:       mandyville-data
Version:    0.2
Release:    20%{?dist}
Summary:    Data fetching and data storage for mandyville.

License:    MIT
URL:        https://github.com/sirgraystar/mandyville-data
Source0:    %{name}-%{version}-%{release}.tar.gz

BuildRequires: systemd-rpm-macros
Requires:   moreutils
Requires:   perl(Array::Utils)
Requires:   perl(Capture::Tiny)
Requires:   perl(Const::Fast)
Requires:   perl(Cpanel::JSON::XS)
Requires:   perl(DateTime)
Requires:   perl(DateTime::TimeZone)
Requires:   perl(Dir::Self)
Requires:   perl(DBD::Pg)
Requires:   perl(DBI)
Requires:   perl(File::Temp)
Requires:   perl(Mojo::Base)
Requires:   perl(Mojolicious)
Requires:   perl(SQL::Abstract::More)
Requires:   perl(Text::LevenshteinXS)
Requires:   perl(Try::Tiny)
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
install -dm755 %{buildroot}%{_unitdir}/
install -Dm644 etc/systemd/system/* %{buildroot}%{_unitdir}/

# Libraries
install -dm755 %{buildroot}%{perl_vendorlib}/Mandyville/
cp -a lib/Mandyville/* %{buildroot}%{perl_vendorlib}/Mandyville/

%files
%defattr(-,root,root,-)

# Binaries
%{_bindir}/send-healthcheck
%{_bindir}/update-competition-data
%{_bindir}/update-fixture-data
%{_bindir}/update-fpl-availability
%{_bindir}/update-fpl-classic
%{_bindir}/update-fpl-draft
%{_bindir}/update-fpl-info
%{_bindir}/update-understat-ids
%{_bindir}/update-understat-info
%{_bindir}/fpl-deadline-reminders

# Crons
%{_sysconfdir}/cron.d/update-competition-data
%{_sysconfdir}/cron.d/update-fixture-data
%{_sysconfdir}/cron.d/update-fpl-availability
%{_sysconfdir}/cron.d/update-fpl-classic
%{_sysconfdir}/cron.d/update-fpl-draft
%{_sysconfdir}/cron.d/update-fpl-info
%{_sysconfdir}/cron.d/update-understat-info
%{_unitdir}/fpl-deadline-reminders.service

# Libraries
%{perl_vendorlib}/Mandyville/*.pm
%{perl_vendorlib}/Mandyville/API/*.pm
%{perl_vendorlib}/Mandyville/Notifier/*.pm
%{perl_vendorlib}/Mandyville/Reminders/*.pm

# Config
%config(noreplace) %{_sysconfdir}/mandyville/config.yaml

%post
%systemd_post fpl-deadline-reminders.service


%postun
%systemd_postun_with_restart fpl-deadline-reminders.service

%clean
rm -rf $RPM_BUILD_ROOT

%changelog
* Fri Aug 21 2026 Owen Davies <owen@odavi.es> - 0.2-20
- Update submodule
- Rework player name matching to account for recent findings
- Update merge-duplicate-players to account for new tables

* Thu Aug 20 2026 Owen Davies <owen@odavi.es> - 0.2-19

* Thu Aug 20 2026 Owen Davies <owen@odavi.es> - 0.2-18
- Update gitignore
- Add FPL deadline reminders and classic entry tracking

* Thu Aug 20 2026 Owen Davies <owen@odavi.es> - 0.2-17
- Parse expected return date from FPL news text
- Correct changelog date
- Ignore draft rank from availability change processing
- Update submodle
- Update submodule
- Add FPL Draft and availability sync crons

* Tue Aug 18 2026 Owen Davies <owen@odavi.es> - 0.2-16
- Add crons for FPL Draft league state and player availability
- Update submodule

* Sun Aug 16 2026 Owen Davies <owen@odavi.es> - 0.2-15
- Don't override team assignments to previously assigned players
- Update agents.md

* Sun Aug 16 2026 Owen Davies <owen@odavi.es> - 0.2-14
- Move backfill script to unpackaged directory
- Update submodule
- Fix conflicting fixtures in the same season
- Update submodule
- Add players_teams tracking, add national team tracking
- Update submodule
- Store starting FPL teams for the current season
- Update submodule
- Get season starting prices for FPL players
- Set active flag on fpl_season_info during gameweek backfill

* Wed Aug 12 2026 Owen Davies <owen@odavi.es> - 0.2-13
- Get fixture team performance data from understat

* Wed Aug 12 2026 Owen Davies <owen@odavi.es> - 0.2-12
- Update understat fetching logic to account for new data structure

* Wed Aug 12 2026 Owen Davies <owen@odavi.es> - 0.2-11
- Remove old scratch md files
- Update submodule
- Add support for marking FPL players as active in a certain season
- Update gitignore
- Add Rodri duplicate to merge script

* Tue Aug 11 2026 Owen Davies <owen@odavi.es> - 0.2-10

* Tue Aug 11 2026 Owen Davies <owen@odavi.es> - 0.2-9
- Don't include merge commits in changelog entries
- Correct null minutes insertion bug

* Tue Aug 11 2026 Owen Davies <owen@odavi.es> - 0.2-8
- Merge branch 'main' of github.com:sirgraystar/mandyville-data
- Add retries on empty API responses
- Fix gameweek ordering

* Tue Aug 11 2026 Owen Davies <owen@odavi.es> - 0.2-7
- Merge branch 'main' of github.com:sirgraystar/mandyville-data
- Give more information when hitting API errors

* Mon Aug 10 2026 Owen Davies <owen@odavi.es> - 0.2-6
- Upgrade to V4 football data API
- Update gitignore

* Mon Aug 10 2026 Owen Davies <owen@odavi.es> - 0.0-2.5
Use HTTPS for football-data API

* Sun Aug 9 2026 Owen Davies <owen@odavi.es> - 0.0-2.4
- Allow fixtures_gameweeks updating to be done for arbitrary years

* Sun Aug 8 2021 Owen Davies <owen@odavi.es> - 0.0-2-3
- Skip fixtures with missing team data in update-fixture-data

* Wed May 5 2021 Owen Davies <owen@odavi.es> - 0.0-2-2
- Use correct player ID when inserting FPL gameweek info

* Mon Apr 12 2021 Owen Davies <owen@odavi.es> - 0.0-2-1
- Update FPL information regularly
- Add support for storing future fixture data

* Sun Apr 04 2021 Owen Davies <owen@odavi.es> - 0.0.1-10
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
