## Data

![Tests](https://github.com/sirgraystar/mandyville-data/actions/workflows/test.yml/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/sirgraystar/mandyville-data/badge.svg)](https://coveralls.io/github/sirgraystar/mandyville-data)

Data fetching, external API interaction and data storage for mandyville.

### Requirements

#### Running
* Perl 5.20+
* Everything in the `cpanfile` in the root of this repo

If you've installed your dependancies locally, you'll need to set
`PERL5LIB` to the path to those when running the scripts in `/bin`.
You'll also need to pass the `-I` flag if you're running on a machine
where the mandyville libs aren't installed:

```
PERL5LIB=/path/to/deps/lib/perl5/ perl -Ilib ./bin/update-competition-data
```

#### Testing
* Install `cpanm` with `dnf install cpanminus`
* Run `cpanm --installdeps --notest .` to fetch the dependancies
* Run `prove -lr t` to run the tests. You'll probably need to set the
  following environment variables:
  * `MANDYVILLE_DB_HOST` - the hostname of your testing db. Can be set
    in `etc/mandyville/config.yaml` instead.
  * `MANDYVILLE_DB_PASS` - the password of your testing db. Can be set
    in `etc/mandyville/config.yaml` instead.
  * `PERL5LIB` - the path to your `cpanm` dependencies 

