#!/bin/sh
#
# deploy.sh
# =========
# Deploys mandyville-data to a remote yum repository. 
# Runs through the following steps:
#   * Creates a tarball of the current checkout
#   * Builds an RPM from that tarball using the specfile
#   * Uploads the RPM to the specified repository
# Provide the hostname of the remote repository and the path to the 
# package directory on the remote repository as arguments to this
# script. You can also specify a package name and a checkout name
# if they're something non-standard.

REPO_HOST=$1
REPO_PATH=$2
PACKAGE_NAME=$3
CHECKOUT_NAME=$4

if [ -z "$REPO_HOST" ]; then
    echo "Needs a repo host as first argument"
    exit 1
fi

if [ -z "$REPO_PATH" ]; then
    echo "Needs a repo path as second argument"
    exit 1
fi

if [ -z "$PACKAGE_NAME" ]; then
    echo "No specfile provided, using default"
    PACKAGE_NAME='mandyville-data'
fi

if [ -z "$CHECKOUT_NAME" ]; then
    echo "No checkout name provided, using default"
    CHECKOUT_NAME='data/'
fi

CWD=${0%/*}
DIST='el8'
SOURCE_DIR="$HOME/rpmbuild/SOURCES"
RPM_DIR="$HOME/rpmbuild/RPMS/x86_64"

VERSION=$(grep Version $CWD/$PACKAGE_NAME.spec | grep -oP '\d+\.\d+')
RELEASE=$(grep Release $CWD/$PACKAGE_NAME.spec | grep -oP '\d+')

PACKAGE=$PACKAGE_NAME-$VERSION-$RELEASE.$DIST

echo "Tarballing $PACKAGE"

cd "$CWD/../"

tar -czf $PACKAGE.tar.gz $CHECKOUT_NAME

mkdir -p $SOURCE_DIR

mv $PACKAGE.tar.gz $SOURCE_DIR

cd $CHECKOUT_NAME

echo "Building RPM"

rpmbuild -ba --quiet $PACKAGE_NAME.spec

RPM_NAME="$PACKAGE.x86_64.rpm"

echo "Uploading RPM"

scp $RPM_DIR/$RPM_NAME root@$REPO_HOST:$REPO_PATH/$RPM_NAME

ssh root@$REPO_HOST createrepo --update $REPO_PATH

echo "Done!"

