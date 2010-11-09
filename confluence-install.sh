#!/bin/bash

# Script for installing Atlassian Confluence 3.2.1 on a minimal Ubuntu 10.04 server
#
# IMPORTANT: You need to run the JIRA installation script first!
#

#get some parameters
echo "server name:"
read servername
echo "administrator email:"
read adminemail
echo "Confluence database password:"
read dbpass

#some settings
confluenceversion="3.3"
confluencebuild="confluence-$confluenceversion"
confluencedownload="$confluencebuild.tar.gz"

# install some utilities
sudo apt-get install unzip ed -y
sudo apt-get install apache2 -y
sudo apt-get install openjdk-6-jdk -y
sudo apt-get install tomcat6 tomcat6-user -y
sudo apt-get install libapr1 libtcnative-1 libapache2-mod-jk -y

# install postgresql
sudo apt-get install postgresql -y

# enable the SSL module in apache
sudo a2enmod ssl
sudo /etc/init.d/apache2 restart

# generate certificates for the web server:
openssl genrsa -des3 -out $servername.key 1024
openssl rsa -in $servername.key -out $servername.key.insecure
mv $servername.key $servername.key.secure
mv $servername.key.insecure $servername.key
openssl req -new -key $servername.key -out $servername.csr

# generate self-signed certificate
openssl x509 -req -days 365 -in $servername.csr -signkey $servername.key -out $servername.crt

# copy certificates to proper location
sudo cp $servername.crt /etc/ssl/certs
sudo cp $servername.key /etc/ssl/private

# point apache to the correct certificates
sudo sed -i "s/ssl-cert-snakeoil.pem/$servername.crt/" /etc/apache2/sites-available/default-ssl
sudo sed -i "s/ssl-cert-snakeoil.key/$servername.key/" /etc/apache2/sites-available/default-ssl

# update the server name and admin email
sudo sed -i "s/webmaster@localhost/$adminemail/" /etc/apache2/sites-available/default-ssl
sudo sed -i "3a\        ServerName $servername" /etc/apache2/sites-available/default-ssl

# enable secure site
sudo a2ensite default-ssl
sudo /etc/init.d/apache2 reload


# create a Confluence user
sudo adduser --system --shell /bin/sh --gecos 'Confluence owner' --group --disabled-password --home /srv/confluence confluence

# create a tomcat instance for Confluence
sudo su - -c "tomcat6-instance-create -p 8280 -c 8205 tomcat" confluence

# configure the tomcat instance for Confluence
sudo ed /srv/confluence/tomcat/conf/server.xml << doit
27d
25d
69
i
<!--
.
74
i
-->
.
95d
93d
93,93 s/8009/8209/
.
93,93 s/8443/443/
.
w
q
doit

# add Confluence tomcat instance to mod_jk
sudo touch /etc/apache2/workers.properties
sudo sed -i 's/worker.list=jira/worker.list=jira,confluence/' /etc/apache2/workers.properties
sudo ed /etc/apache2/workers.properties << doit
$
a
worker.confluence.port=8209
worker.confluence.host=localhost
worker.confluence.type=ajp13
.
w
q
doit

sudo ed /etc/apache2/sites-available/default-ssl << doit
8
i
        JkMount /confluence confluence
        JkMount /confluence/* confluence
.
w
q
doit

/etc/init.d/apache2 restart

# create Confluence init script
sudo touch /etc/init.d/confluence
sudo ed /etc/init.d/confluence << doit
i
#!/bin/sh

case \$1 in
        start)
                su -c "sh /srv/confluence/tomcat/bin/startup.sh" confluence
        ;;

        stop)
                su -c "sh /srv/confluence/tomcat/bin/shutdown.sh" confluence
        ;;

        restart)
                su -c "sh /srv/confluence/tomcat/bin/shutdown.sh" confluence
                su -c "sh /srv/confluence/tomcat/bin/startup.sh" confluence
        ;;
esac
exit 0
.
w
q
doit

sudo chmod +x /etc/init.d/confluence

# create postgresql user for jira
sudo su - -c "psql -c \"create user confuser with encrypted password '$dbpass' createdb createuser\" template1" postgres
sudo su - -c "createdb -O confuser confluence" postgres

# download confluence
sudo su - -c "wget http://www.atlassian.com/software/confluence/downloads/binary/$confluencedownload" confluence
sudo su - -c "tar -xvzf $confluencedownload" confluence
sudo su - -c "rm $confluencedownload" confluence
sudo su - -c "mv $confluencebuild build" confluence

sudo su - -c "mkdir confluence-home" confluence
sudo sed -i '$a\confluence.home=/srv/confluence/confluence-home' /srv/confluence/build/confluence/WEB-INF/classes/confluence-init.properties

# create datasource in Tomcat
sudo ed /srv/confluence/tomcat/conf/server.xml <<doit
134,147d
134
i
        <Context path="/confluence" docBase="confluence.war" reloadable="false">
          <Resource name="jdbc/ConfluenceDS" auth="Container" type="javax.sql.DataSource"
            username="confuser"
            password="DBPASS"
            driverClassName="org.postgresql.Driver"
            url="jdbc:postgresql://localhost/confluence"
           />
        </Context>
.
w
q
doit

sudo sed -i "s/DBPASS/$dbpass/" /srv/confluence/tomcat/conf/server.xml

# fix tomcat memory settings
sudo sed -i '$a\CATALINA_OPTS="$CATALINA_OPTS -Dorg.apache.jasper.runtime.BodyContentImpl.LIMIT_BUFFER=true -Dmail.mime.decodeparameters=true -Xms128m -Xmx512m -XX:MaxPermSize=256m"' /srv/confluence/tomcat/bin/setenv.sh

# build confluence
sudo su - -c 'cd build;sh build.sh' confluence
sudo su - -c "cp /srv/confluence/build/dist/$confluencebuild.war /srv/confluence/tomcat/webapps/confluence.war"

# start confluence
sudo /etc/init.d/confluence start
sudo update-rc.d confluence defaults

sudo /etc/init.d/apache2 restart
#done
echo "Confluence installation complete. Open your browser and go to https://$servername/confluence to complete the configuration"
echo ""
echo "You should choose the production installation and an external database of type PostgreSQL. The name of the datasource is java:comp/env/jdbc/ConfluenceDS"



