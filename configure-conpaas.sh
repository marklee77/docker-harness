#!/bin/bash -e
# Copyright (c) 2010-2012, Contrail consortium.
# All rights reserved.
#
# Redistribution and use in source and binary forms, 
# with or without modification, are permitted provided
# that the following conditions are met:
#
#  1. Redistributions of source code must retain the
#     above copyright notice, this list of conditions
#     and the following disclaimer.
#  2. Redistributions in binary form must reproduce
#     the above copyright notice, this list of 
#     conditions and the following disclaimer in the
#     documentation and/or other materials provided
#     with the distribution.
#  3. Neither the name of the Contrail consortium nor the
#     names of its contributors may be used to endorse
#     or promote products derived from this software 
#     without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
# CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR 
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
# OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

##
# THIS SCRIPT HAS BEEN __GENERATED__ from the configuration file 'create-img-script.cfg'
# running command 'python create-img-script.py'.
#
# This script generates a VM image for ConPaaS, to be used for OpenNebula with KVM.
# The script should be run on a Debian or Ubuntu system.
# Before running this script, please make sure that you have the following
# executables in your $PATH:
#
# dd parted losetup kpartx mkfs.ext3 tune2fs mount debootstrap chroot umount grub-install (grub2)
# 
# NOTE: This script requires the installation of Grub 2 (we recommend Grub 1.98 or newer,
# as we experienced problems with 1.96). 
##

#########################
export LC_ALL=C

# Function for displaying highlighted messages.
function cecho() {
  echo -en "\033[1m"
  echo -n "#" $@
  echo -e "\033[0m"
}

UBUNTU_DIST=trusty

# The architecture and kernel version for the OS that will be installed (please make
# sure to modify the kernel version name accordingly if you modify the architecture).
CLOUD=openstack
ARCH=amd64
KERNEL=linux-image-amd64


# Section: 003-create-image
if [ `id -u` -ne 0 ]; then
  cecho 'need root permissions for this script';
  exit 1;
fi

cecho "Changing hostname"
cat <<EOF > $ROOT_DIR/etc/hostname
conpaas
EOF

echo '127.0.0.1  conpaas' >> $ROOT_DIR/etc/hosts

# Section: 004-ConPaaS-core

GIT_SERVICE="false"

# Generate a script that will install the dependencies in the system. 
cat <<EOF > $ROOT_DIR/conpaas_install
#!/bin/bash
# Function for displaying highlighted messages.
function cecho() {
  echo -en "\033[1m"
  echo -n "#" \$@
  echo -e "\033[0m"
}

# set root passwd
echo "root:contrail" | chpasswd

# fix apt sources
#sed --in-place 's/main/main contrib non-free/' /etc/apt/sources.list

export DEBIAN_FRONTEND=noninteractive

# install NTP to get the corret date for generated certificate
apt-get -q -y install ntp

# install curl that works better than wget in some scenarios
apt-get -q -y install curl


# install dependencies
apt-get -y update
# pre-accept sun-java6 licence
echo "debconf shared/accepted-sun-dlj-v1-1 boolean true" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes --no-install-recommends --no-upgrade \
        install openssh-server wget \
                python python-pycurl python-openssl python-m2crypto \
                ganglia-monitor gmetad rrdtool logtail \
                python-cheetah python-netaddr libxslt1-dev yaws subversion unzip less
update-rc.d yaws disable
update-rc.d gmetad disable
update-rc.d ganglia-monitor disable

# remove cached .debs from /var/cache/apt/archives to save disk space
apt-get clean

# create directory structure
echo > /var/log/cpsagent.log
mkdir -p /etc/cpsagent/
mkdir -p /var/tmp/cpsagent/
mkdir -p /var/run/cpsagent/
mkdir -p /var/cache/cpsagent/
echo > /var/log/cpsmanager.log
mkdir -p /etc/cpsmanager/
mkdir -p /var/tmp/cpsmanager/
mkdir -p /var/run/cpsmanager/
mkdir -p /var/cache/cpsmanager/

EOF

# Section: 501-php

cat <<EOF >> $ROOT_DIR/conpaas_install
cecho "===== add dotdeb repo for php fpm ====="
apt-get -y update
apt-get -y --no-install-recommends --no-upgrade install php5-fpm php5-curl \
        php5-mcrypt php5-mysql php5-odbc php5-pgsql php5-sqlite php5-sybase php5-xmlrpc \
        php5-xsl php5-adodb php5-memcache php5-gd nginx git tomcat6-user memcached

# For autoscaling
apt-get -y --no-install-recommends --no-upgrade install libatlas-base-dev libatlas3gf-base \
    python-dev python-scipy python-setuptools python-simplejson gfortran g++
easy_install numpy
easy_install -U numpy
easy_install pandas 
easy_install patsy 
easy_install statsmodels

update-rc.d php5-fpm disable
update-rc.d memcached disable
update-rc.d nginx disable

# remove dotdeb repo
sed --in-place 's%deb http://packages.dotdeb.org wheezy all%%' /etc/apt/sources.list
apt-get -y update

# remove cached .debs from /var/cache/apt/archives to save disk space
apt-get clean

EOF

if [ $GIT_SERVICE = "false" ] ; then
GIT_SERVICE="true"

cat <<EOF >> $ROOT_DIR/conpaas_install
cecho "===== install GIT ====="
# add git user
(useradd git --shell /usr/bin/git-shell --create-home -k /dev/null) || true
# create ~git/.ssh and authorized_keys
install -d -m 700 --owner=git --group=git /home/git/.ssh
install -m 600 --owner=git --group=git /dev/null ~git/.ssh/authorized_keys
# create default repository
git init --bare ~git/code
# create SSH key for manager -> agent access
ssh-keygen -N "" -f ~root/.ssh/id_rsa
echo StrictHostKeyChecking no > ~root/.ssh/config
# allow manager -> agent passwordless pushes
cat ~root/.ssh/id_rsa.pub > ~git/.ssh/authorized_keys
# fix repository permissions
chown -R git:git ~git/code

EOF
fi

# Section: 502-galera

cat <<EOF >> $ROOT_DIR/conpaas_install

#apt-get -y update
#apt-get install libssl0.9.8
#DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes --no-install-recommends --no-upgrade install \
#		psmisc libaio1 libdbi-perl libdbd-mysql-perl mysql-client rsync python-mysqldb make

#wget https://launchpad.net/galera/3.x/25.3.1/+download/galera-25.3.1-amd64.deb
#dpkg -i galera-25.3.1-amd64.deb
#wget https://launchpad.net/codership-mysql/5.6/5.6.16-25.5/+download/mysql-server-wsrep-5.6.16-25.5-amd64.deb
#dpkg -i mysql-server-wsrep-5.6.16-25.5-amd64.deb


## Added more wait time before deciding whether the mysql daemon has failed to start (idem for stopping)
#sed -i 's/1 2 3 4 5 6.*;/\$(seq 60);/' /etc/init.d/mysql


## Install Galera Load Balancer (glb)

##installation of prerequisites
#apt-get -y install git autoconf libtool
##download the lastest version from git-hub  
#rm -rf glb
#git clone https://github.com/codership/glb
##configuration build and installation  
#cd glb
#./bootstrap.sh
#./configure
#make
#make install
#cp -a ./files/glbd.sh /etc/init.d/glbd
#cp -a ./files/glbd.cfg /etc/default/glbd
## using default listen port 8010
#sed -i 's/#LISTEN_ADDR/LISTEN_ADDR/' /etc/default/glbd
## using default listen port 8011
### wait 1 second after EOF to close nc
#sed -i 's/#CONTROL_ADDR/CONTROL_ADDR/' /etc/default/glbd
#sed -i 's/nc \$CONTROL_IP/nc -q 1 \$CONTROL_IP/' /etc/init.d/glbd
#cd ..
#rm -fr glb-\${glb_version} glb-\${glb_version}.tar.gz


EOF
# Section: 503-condor

cat <<EOF >> $ROOT_DIR/conpaas_install
#cecho "===== install packages required by HTCondor ====="
## avoid warning: W error: http://mozilla.debian.net squeeze-backports Release: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 85A3D26506C4AE2A 
##apt-get install debian-keyring
#wget -O - -q http://mozilla.debian.net/archive.asc | apt-key add -
## avoid warning: W: GPG error: http://dl.google.com stable Release: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY A040830F7FAC5991 
#wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | apt-key add -
#wget -qO - http://research.cs.wisc.edu/htcondor/debian/HTCondor-Release.gpg.key | sudo apt-key add -
## If things go wrong, you may want to read  http://research.cs.wisc.edu/htcondor/debian/
## 
## added [arch=amd64 trusted=yes] to avoid authentication warning
#echo "deb [arch=amd64 trusted=yes] http://research.cs.wisc.edu/htcondor/debian/stable/ wheezy contrib" >> /etc/apt/sources.list
#apt-get update
#if [ $UBUNTU_DIST == "squeeze" ]
#then
#    DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes --no-install-recommends --no-upgrade \
#        install sun-java6-jdk ant condor sudo xvfb
#elif [ $UBUNTU_DIST == "trusty" ]
#then
#    DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes --no-install-recommends --no-upgrade \
#        install openjdk-7-jre-headless ant condor sudo xvfb
#else
#    echo "Error: unknown Debian distribution '$UBUNTU_DIST': cannot select correct Condor packages."
#    exit 1
#fi

## next 12 lines moved here from conpaas-services/scripts/manager/htc-manager-start
#apt-get update -y 
#echo ==== python-setuptools 
#apt-get install python-setuptools -y 
#sleep 2
#echo ==== pip  
#easy_install -U distribute
#easy_install pip 
#sleep 2
#echo PATH=$PATH 
#export PATH=$PATH:/usr/local/bin
#echo PATH=$PATH 
#echo ==== xmltodict  
#pip install xmltodict 

## remove cached .debs from /var/cache/apt/archives to save disk space
#apt-get clean
EOF

# Section: 504-selenium

cat <<EOF >> $ROOT_DIR/conpaas_install
#cecho "===== install SELENIUM ====="

#if [ $UBUNTU_DIST == "squeeze" ]
#then
#    # recent versions of iceweasel and chrome
#    echo "deb http://backports.debian.org/debian-backports $UBUNTU_DIST-backports main" >> /etc/apt/sources.list
#    echo "deb http://mozilla.debian.net/ $UBUNTU_DIST-backports iceweasel-esr" >> /etc/apt/sources.list

#    apt-get -y update
#    apt-get -y --force-yes install -t $UBUNTU_DIST-backports iceweasel
#    apt-get -y --force-yes install xvfb xinit chromium-browser sun-java6-jdk
#elif [ $UBUNTU_DIST == "trusty" ]
#then
#    apt-get -y update
#    apt-get -y --force-yes install iceweasel xvfb xinit chromium-browser openjdk-7-jre-headless
#else
#    echo "Error: unknown Debian distribution '$UBUNTU_DIST': cannot select correct Selenium packages."
#    exit 1
#fi

EOF

# Section: 505-hadoop

cat <<EOF >> $ROOT_DIR/conpaas_install
#cecho "===== install cloudera repo for hadoop ====="
## add cloudera repo for hadoop
#if [ "$UBUNTU_DIST" == "trusty" ]
#then
#  hadoop_dist="squeeze"
#else
#  hadoop_dist="$UBUNTU_DIST"
#fi
#echo "deb http://archive.cloudera.com/debian \${hadoop_dist}-cdh3 contrib" >> /etc/apt/sources.list
#wget -O - http://archive.cloudera.com/debian/archive.key 2>/dev/null | apt-key add -
#apt-get -y update
#apt-get -y --no-install-recommends --no-upgrade install \
#  hadoop-0.20 hadoop-0.20-namenode hadoop-0.20-datanode \
#  hadoop-0.20-secondarynamenode hadoop-0.20-jobtracker  \
#  hadoop-0.20-tasktracker hadoop-pig hue-common  hue-filebrowser \
#  hue-jobbrowser hue-jobsub hue-plugins hue-server dnsutils
#update-rc.d hadoop-0.20-namenode disable
#update-rc.d hadoop-0.20-datanode disable
#update-rc.d hadoop-0.20-secondarynamenode disable
#update-rc.d hadoop-0.20-jobtracker disable
#update-rc.d hadoop-0.20-tasktracker disable
#update-rc.d hue disable
## create a default config dir
#mkdir -p /etc/hadoop-0.20/conf.contrail
#update-alternatives --install /etc/hadoop-0.20/conf hadoop-0.20-conf /etc/hadoop-0.20/conf.contrail 99
## remove cloudera repo
#sed --in-place "s%deb http://archive.cloudera.com/debian \${hadoop_dist}-cdh3 contrib%%" /etc/apt/sources.list
#apt-get -y update


EOF

# Section: 506-scalaris

cat <<EOF >> $ROOT_DIR/conpaas_install
#cecho "===== install scalaris repo ====="
# add scalaris repo
#echo "deb http://download.opensuse.org/repositories/home:/scalaris/Debian_6.0 /" >> /etc/apt/sources.list
#wget -O - http://download.opensuse.org/repositories/home:/scalaris/Debian_6.0/Release.key 2>/dev/null | apt-key add -
#apt-get -y update
#apt-get -y --no-install-recommends --no-upgrade install scalaris screen erlang
#update-rc.d scalaris disable
## remove scalaris repo
#sed --in-place 's%deb http://download.opensuse.org/repositories/home:/scalaris/Debian_6.0 /%%' /etc/apt/sources.list
#apt-get -y update

EOF

# Section: 507-xtreemfs

cat <<EOF >> $ROOT_DIR/conpaas_install
#cecho "===== install xtreemfs repo ====="
## add xtreemfs repo
#if [ "$UBUNTU_DIST" == "squeeze" ]
#then
#    echo "deb http://download.opensuse.org/repositories/home:/xtreemfs:/unstable/Debian_6.0 /" >> /etc/apt/sources.list
#    wget -O - http://download.opensuse.org/repositories/home:/xtreemfs:/unstable/Debian_6.0/Release.key 2>/dev/null | apt-key add -
#elif [ "$UBUNTU_DIST" == "trusty" ]
#then
#    echo "deb http://download.opensuse.org/repositories/home:/xtreemfs:/unstable/Debian_7.0 /" >> /etc/apt/sources.list
#    wget -O - http://download.opensuse.org/repositories/home:/xtreemfs:/unstable/Debian_7.0/Release.key 2>/dev/null | apt-key add -
#else
#    echo "ERROR: unknown Debian distribution '$UBUNTU_DIST'."
#    exit 1
#fi
#apt-get -y update
#apt-get -y --no-install-recommends --no-upgrade install xtreemfs-server xtreemfs-client xtreemfs-tools
#update-rc.d xtreemfs-osd disable
#update-rc.d xtreemfs-mrc disable
#update-rc.d xtreemfs-dir disable
## remove xtreemfs repo
#sed --in-place 's%deb http://download.opensuse.org/repositories/home:/xtreemfs:/unstable/Debian_..0 /%%' /etc/apt/sources.list
#apt-get -y update

EOF

# Section: 995-rm-unused-pkgs

cat <<EOF > $ROOT_DIR/conpaas_rm
#!/usr/bin/python

from subprocess import Popen
from subprocess import PIPE
import re
import sys

# Define which are the 'root' packages (from
# which the dependency analysis starts)

print "rm unused packages script starting ..."

debian_pkgs = ['linux-image-xen-amd64', 'linux-image-amd64', 'linux-image-xen-686', 'linux-image-686',
               'initramfs-tools', 'bash', 'apt', 'apt-utils', 'cron',
               'vim-tiny', 'grub-common', 'grub', 'grub-pc', 'net-tools',
               'iputils-ping', 'rsyslog', 'binfmt-support', 'dbus',
               'avahi-daemon', 'libavahi-core7', 'libdaemon0', 'libnss-mdns',
               'bsdmainutils', 'resolvconf', 'netbase', 'iproute', 'ifupdown',
               'isc-dhcp-common', 'isc-dhcp-client', 'wget']

core_pkgs = ['openssh-server', 'python', 'python-pycurl', 'python-openssl',
             'python-m2crypto', 'python-cheetah', 'libxslt1-dev', 'yaws',
             'subversion', 'unzip', 'less', 'ipop', 'ntp', 'curl',
             'ganglia-monitor', 'gmetad', 'rrdtool', 'logtail', 'python-netaddr']

php_pkgs = ['php5-fpm', 'php5-curl', 'php5-mcrypt', 'php5-mysql', 'php5-odbc',
            'php5-pgsql', 'php5-sqlite', 'php5-sybase', 'php5-xmlrpc',
            'php5-xsl', 'php5-adodb', 'php5-memcache', 'php5-gd', 'nginx',
            'git', 'tomcat6-user', 'memcached', 'python-scipy', 'python-simplejson',
            'libatlas-base-dev', 'libatlas3gf-base', 'python-dev', 'python-setuptools']

galera_pkgs = ['galera', 'mysql-server-wsrep', 'python-mysqldb', 'rsync']

if "$UBUNTU_DIST" == "squeeze":
    condor_pkgs = ['sun-java6-jdk', 'ant', 'condor', 'sudo', 'xvfb']
else:
    condor_pkgs = ['openjdk-7-jre-headless', 'ant', 'condor', 'sudo', 'xvfb']

if "$UBUNTU_DIST" == "squeeze":
    selenium_pkgs = ['iceweasel', 'xvfb', 'xinit', 'chromium-browser','sun-java6-jdk']
else:
    selenium_pkgs = ['iceweasel', 'xvfb', 'xinit', 'chromium-browser','openjdk-7-jre-headless']

hadoop_pkgs =   ['hadoop-0.20', 'hadoop-0.20-namenode', 'hadoop-0.20-datanode',
                'hadoop-0.20-secondarynamenode', 'hadoop-0.20-jobtracker',
                'hadoop-0.20-tasktracker', 'hadoop-pig', 'hue-common',
                'hue-filebrowser', 'hue-jobbrowser', 'hue-jobsub',
                'hue-plugins', 'hue-server', 'dnsutils']

scalaris_pkgs = ['scalaris', 'screen', 'erlang']

xtreemfs_pkgs = ['xtreemfs-server', 'xtreemfs-client', 'xtreemfs-tools']

cds_pkgs = ['php5-fpm', 'php5-curl', 'php5-mcrypt', 'php5-mysql', 'php5-odbc',
            'php5-pgsql', 'php5-sqlite', 'php5-sybase', 'php5-xmlrpc',
            'php5-xsl', 'php5-adodb', 'php5-memcache', 'php5-gd git',
            'tomcat6-user', 'memcached',
            'libpcre3-dev', 'libssl-dev', 'libgeoip-dev', 'libperl-dev']


# Execute shell command
def shell_cmd(cmd):
    return Popen(cmd, stdout=PIPE, shell=True).stdout.read()

# Take the output of a shell command and return a list
# of tokens from it
def string_to_list(s):
    # Normalize whitespace to single spaces
    s = re.sub(r'\s+', ' ', s);
    return s.split()

def write_to_file(filename, data):
	f = open(filename, 'w')
	print >> f, data
	f.close()

def remove_pkg(pkg):
    return shell_cmd("apt-get -y purge %s 2>&1 " % pkg)

def force_remove_pkg(pkg):
    return shell_cmd("echo 'Yes, do as I say!' | apt-get -y --force-yes purge %s 2>&1 " % pkg)

def doublecheck_unneeded_pkgs(unneeded_pkgs):
    to_keep = []
    to_remove = []
    to_remove_with_wornings = []
    for pkg in unneeded_pkgs:
        output = shell_cmd('apt-get -s purge %s ' % pkg)
        warn = re.findall(r'WARNING: The following essential packages will be removed.', output)

        output = re.findall(r'The following packages will be REMOVED:(.*?)^\S', output, re.S | re.M)

        l = len(output)
        if l == 0:
            print  '%s does not have a remove list' % pkg
            continue

        if l > 1:
            sys.exit('Error: More than one list of packages to be removed.')

        # Unpack from list
        output = output[0]
        # Remove '*' chars
        output = re.sub(r'\*', '', output);
        output = string_to_list(output)
        output = set(output)

        if len(output.intersection(needed_pkgs)) > 0:
            to_keep.append(pkg)
        else:
            if warn:
                to_remove_with_wornings.append(pkg)
            else:
                to_remove.append(pkg)

    return to_keep, to_remove, to_remove_with_wornings


# Necessary packages
args = sys.argv[1:]
pkgs = []
pkgs.extend(debian_pkgs)
pkgs.extend(core_pkgs)

if len(args) == 0:
    sys.exit('The script needs at least one of the arguments: '
    '--all, --none, --php, --condor, --selenium, --hadoop, --scalaris, --xtreemfs, --cds, --debug.')

if '--debug' in args:
	dbg = True
	args.remove('--debug')
else:
	dbg = False

if '--all' in args:
    pkgs.extend(php_pkgs)
    pkgs.extend(condor_pkgs)
    pkgs.extend(selenium_pkgs)
    pkgs.extend(hadoop_pkgs)
    pkgs.extend(scalaris_pkgs)
    pkgs.extend(xtreemfs_pkgs)
    pkgs.extend(cds_pkgs)
    args.remove('--all')
elif '--none' in args:
    args.remove('--none')
else:
    if '--php' in args:
        pkgs.extend(php_pkgs)
        args.remove('--php')
    if '--galera' in args:
        pkgs.extend(galera_pkgs)
        args.remove('--galera')
    if '--condor' in args:
        pkgs.extend(condor_pkgs)
        args.remove('--condor')
    if '--selenium' in args:
        pkgs.extend(selenium_pkgs)
        args.remove('--selenium')
    if '--hadoop' in args:
        pkgs.extend(hadoop_pkgs)
        args.remove('--hadoop')
    if '--scalaris' in args:
        pkgs.extend(scalaris_pkgs)
        args.remove('--scalaris')
    if '--xtreemfs' in args:
        pkgs.extend(xtreemfs_pkgs)
        args.remove('--xtreemfs')
    if '--cds' in args:
        pkgs.extend(cds_pkgs)
        args.remove('--cds')

if args:
    sys.exit('Error: Unrecognized or duplicate arguments: %s' % str(args))

# Install apt-rdepends
print shell_cmd('apt-get -y install apt-rdepends 2>&1 ')

# Make a list of needed packages
needed_pkgs = set([])
for pkg in pkgs:
    print 'Processing ' + pkg
    needed_pkgs.add(pkg)
    dependencies = shell_cmd('apt-rdepends %s 2>&1 | awk -F"Depends:|PreDepends:" \'/Depends: / || /PreDepends: / { print \$2 }\' | awk \'{print \$1}\'| sort -u' % pkg)

    needed_pkgs.update(string_to_list(dependencies))

needed_pkgs = list(needed_pkgs)
needed_pkgs.sort()
needed_pkgs = set(needed_pkgs)

if (dbg):
    write_to_file('needed_pkgs', needed_pkgs)

# Useful
# shell_cmd("dpkg-query -Wf '\${Installed-Size}\t\t\${Package}\t\t\${Priority}\n' | sort -u")

# Make a list of installed packages
installed_pkgs = shell_cmd("dpkg-query -Wf '\${Package}\n' | sort -u")
installed_pkgs = string_to_list(installed_pkgs)
installed_pkgs = set(installed_pkgs)

if (dbg):
    write_to_file('installed_pkgs', installed_pkgs)

# Find unneeded packages
unneeded_pkgs = installed_pkgs.difference(needed_pkgs)
weird_pkgs = needed_pkgs.difference(installed_pkgs)

# Some of the packages in unneeded_pkgs can still be required
to_keep, to_remove, to_remove_with_wornings = \
    doublecheck_unneeded_pkgs(unneeded_pkgs)
needed_pkgs.update(to_keep)
unneeded_pkgs = to_remove + to_remove_with_wornings

if (dbg):
    write_to_file('to_remove', to_remove)
    write_to_file('to_remove_with_wornings', to_remove_with_wornings)


print "REMOVING PACKAGES ..."
for p in to_remove:
	print remove_pkg(p), "\n"
print shell_cmd('apt-get -y autoremove 2>&1')

# Free additional space
#apt-get -y install localepurge
#localepurge
#apt-get -y purge localepurge

print shell_cmd('rm -rf /usr/share/doc/ 2>&1')
print shell_cmd('rm -rf /usr/share/doc-base/ 2>&1')
print shell_cmd('rm -rf /usr/share/man/ 2>&1')

EOF
RM_SCRIPT_ARGS=' --php --galera --condor --selenium --hadoop --scalaris --xtreemfs'

# Section: 996-tail

cat <<EOF >> $ROOT_DIR/conpaas_install
apt-get -y clean
exit 0
EOF

# Execute the script for installing the dependencies.
chmod a+x $ROOT_DIR/conpaas_install
source /conpaas_install
rm -f $ROOT_DIR/conpaas_install

rm -f $ROOT_DIR/usr/sbin/policy-rc.d

# Execute the script to remove unneeded pkgs.
if [ -f $ROOT_DIR/conpaas_rm ] ; then
    chmod a+x $ROOT_DIR/conpaas_rm
    chroot $ROOT_DIR /usr/bin/python /conpaas_rm $RM_SCRIPT_ARGS
    rm -f $ROOT_DIR/conpaas_rm
fi
# Section: 998-ec2

cat <<"EOF" > $ROOT_DIR/etc/rc.local

#!/bin/bash
### BEGIN INIT INFO
# Provides:       ec2-get-credentials
# Required-Start: $network
# Required-Stop:  
# Should-Start:   
# Should-Stop:    
# Default-Start:  2 3 4 5
# Default-Stop:   
# Description:    Retrieve the ssh credentials and add to authorized_keys
### END INIT INFO
#
# ec2-get-credentials - Retrieve the ssh credentials and add to authorized_keys
#
# Based on /usr/local/sbin/ec2-get-credentials from Amazon's ami-20b65349
#

prog=$(basename $0)
logger="logger -t $prog"

public_key_url=http://169.254.169.254/1.0/meta-data/public-keys/0/openssh-key
username='root'
# A little bit of nastyness to get the homedir, when the username is a variable
ssh_dir="`eval printf ~$username`/.ssh"
authorized_keys="$ssh_dir/authorized_keys"

# Try to get the ssh public key from instance data.
public_key=`wget -qO - $public_key_url`
if [ -n "$public_key" ]; then
	if [ ! -f $authorized_keys ]; then
		if [ ! -d $ssh_dir ]; then
			mkdir -m 700 $ssh_dir
			chown $username:$username $ssh_dir
		fi
		touch $authorized_keys
		chown $username:$username $authorized_keys
	fi

	if ! grep -s -q "$public_key" $authorized_keys; then
		printf "\n%s" -- "$public_key" >> $authorized_keys
		$logger "New ssh key added to $authorized_keys from $public_key_url"
		chmod 600 $authorized_keys
		chown $username:$username $authorized_keys
	fi
fi

### BEGIN INIT INFO
# Provides:       ec2-run-user-data
# Required-Start: ec2-get-credentials
# Required-Stop:  
# Should-Start:   
# Should-Stop:    
# Default-Start:  2 3 4 5
# Default-Stop:   
# Description:    Run instance user-data if it looks like a script.
### END INIT INFO
#
# Only retrieves and runs the user-data script once per instance.  If
# you want the user-data script to run again (e.g., on the next boot)
# then readd this script with insserv:
#   insserv -d ec2-run-user-data
#
prog=$(basename $0)
logger="logger -t $prog"
instance_data_url="http://169.254.169.254/2008-02-01"


# Retrieve the instance user-data and run it if it looks like a script
user_data_file=$(tempfile --prefix ec2 --suffix .user-data --mode 700)
$logger "Retrieving user-data"
wget -qO $user_data_file $instance_data_url/user-data 2>&1 | $logger

if [ $(file -b --mime-type $user_data_file) = 'application/x-gzip' ]; then
	$logger "Uncompressing gzip'd user-data"
	mv $user_data_file $user_data_file.gz
	gunzip $user_data_file.gz
fi

if [ ! -s $user_data_file ]; then
	$logger "No user-data available"
elif head -1 $user_data_file | egrep -v '^#!'; then
	$logger "Skipping user-data as it does not begin with #!"
else
	$logger "Running user-data"
	$user_data_file 2>&1 | logger -t "user-data"
	$logger "user-data exit code: $?"
fi
rm -f $user_data_file

# Disable this script, it may only run once
# insserv -r $0

### BEGIN INIT INFO
# Provides:       generate-ssh-hostkeys
# Required-Start: $local_fs
# Required-Stop:  
# Should-Start:   
# Should-Stop:    
# Default-Start:  S
# Default-Stop:   
# Description:    Generate ssh host keys if they do not exist
### END INIT INFO

prog=$(basename $0)
logger="logger -t $prog"

rsa_key="/etc/ssh/ssh_host_rsa_key"
dsa_key="/etc/ssh/ssh_host_dsa_key"

# Exit if the hostkeys already exist
if [ -f $rsa_key -a -f $dsa_key ]; then
	exit
fi

# Generate the ssh host keys
[ -f $rsa_key ] || ssh-keygen -f $rsa_key -t rsa -C 'host' -N ''
[ -f $dsa_key ] || ssh-keygen -f $dsa_key -t dsa -C 'host' -N ''

# Output the public keys to the console
# This allows user to get host keys securely through console log
echo "-----BEGIN SSH HOST KEY FINGERPRINTS-----" | $logger
ssh-keygen -l -f $rsa_key.pub | $logger
ssh-keygen -l -f $dsa_key.pub | $logger
echo "------END SSH HOST KEY FINGERPRINTS------" | $logger

exit 0
EOF

trap ":" EXIT
set +e
cleanup
