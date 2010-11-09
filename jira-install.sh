#!/bin/bash

# Script for installing Atlassian Jira 4.1.2 on a minimal Ubuntu 10.04 server
#

#get some parameters
echo "server name:"
read servername
echo "administrator email:"
read adminemail
echo "JIRA database password:"
read dbpass

#some settings
jiraversion="4.1.2"
jirabuild="atlassian-jira-enterprise-$jiraversion"
jiradownload="$jirabuild.tar.gz"
jdbcversion="postgresql-8.4-701.jdbc4"
jdbcdownload="http://jdbc.postgresql.org/download/$jdbcversion.jar"
#install some utilities
sudo apt-get install unzip ed -y

#install apache and tomcat
sudo apt-get install apache2 -y
sudo apt-get install openjdk-6-jdk -y
sudo apt-get install tomcat6 tomcat6-user -y
sudo apt-get install libapr1 libtcnative-1 libapache2-mod-jk -y

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

# disable http site
sudo sed -i "s/webmaster@localhost/$adminemail/" /etc/apache2/sites-available/default
sudo sed -i "2a\        ServerName $servername" /etc/apache2/sites-available/default
sudo sed -i "3a\        Redirect permanent / https://$servername/" /etc/apache2/sites-available/default
sudo /etc/init.d/apache2 reload

# create a JIRA user
sudo adduser --system --shell /bin/sh --gecos 'JIRA owner' --group --disabled-password --home /srv/jira jira

# create a tomcat instance for JIRA
sudo su - -c "tomcat6-instance-create -p 8180 -c 8105 tomcat" jira

# configure the tomcat instance for JIRA
sudo ed /srv/jira/tomcat/conf/server.xml << doit
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
93,93 s/8009/8109/
.
93,93 s/8443/443/
.
w
q
doit

# add JIRA tomcat instance to mod_jk
sudo touch /etc/apache2/workers.properties
sudo ed /etc/apache2/workers.properties << doit
a
worker.list=jira
worker.jira.port=8109
worker.jira.host=localhost
worker.jira.type=ajp13
.
w
q
doit

sudo touch /etc/apache2/conf.d/jk.conf
sudo ed /etc/apache2/conf.d/jk.conf << doit
a
<ifmodule mod_jk.c>
        JkWorkersFile /etc/apache2/workers.properties
        JkLogFile /var/log/apache2/mod_jk.log
        JkLogLevel error
</ifmodule>
.
w
q
doit

sudo ed /etc/apache2/sites-available/default-ssl << doit
5
i

        JkMount /jira jira
        JkMount /jira/* jira
.
w
q
doit

/etc/init.d/apache2 restart

# create JIRA init script
sudo touch /etc/init.d/jira
sudo ed /etc/init.d/jira << doit
i
#!/bin/sh

case \$1 in
        start)
                su -c "sh /srv/jira/tomcat/bin/startup.sh" jira
        ;;

        stop)
                su -c "sh /srv/jira/tomcat/bin/shutdown.sh" jira
        ;;

        restart)
                su -c "sh /srv/jira/tomcat/bin/shutdown.sh" jira
                su -c "sh /srv/jira/tomcat/bin/startup.sh" jira
        ;;
esac
exit 0
.
w
q
doit

sudo chmod +x /etc/init.d/jira

# default Tomcat should not be started
sudo /etc/init.d/tomcat6 stop
sudo update-rc.d -f tomcat6 remove

# install postgresql
sudo apt-get install postgresql -y

# create postgresql user for jira
sudo su - -c "psql -c \"create user jirauser with encrypted password '$dbpass' createdb createuser\" template1" postgres
sudo su - -c "createdb -O jirauser jira" postgres

# download postgresql jdbc driver
sudo wget -O /usr/share/java/$jdbcversion.jar $jdbcdownload
sudo ln -sf /usr/share/java/$jdbcversion.jar /usr/share/tomcat6/lib/$jdbcversion.jar

# download jira
sudo su - -c "wget http://www.atlassian.com/software/jira/downloads/binary/$jiradownload" jira
sudo su - -c "tar -xvzf $jiradownload" jira
sudo su - -c "rm $jiradownload" jira
sudo su - -c "mv $jirabuild build" jira

sudo su - -c "mkdir jira-home" jira
sudo sed -i 's/jira.home =/jira.home = \/srv\/jira\/jira-home/' /srv/jira/build/edit-webapp/WEB-INF/classes/jira-application.properties

sudo sed -i 's/field-type-name="hsql"/field-type-name="postgres72"/' /srv/jira/build/edit-webapp/WEB-INF/classes/entityengine.xml
sudo sed -i 's/schema-name="PUBLIC"/schema-name="public"/' /srv/jira/build/edit-webapp/WEB-INF/classes/entityengine.xml

# create datasource in Tomcat
sudo ed /srv/jira/tomcat/conf/server.xml <<doit
134,147d
134
i
        <Context path="/jira" docBase="jira.war" reloadable="false">
          <Resource name="jdbc/JiraDS" auth="Container" type="javax.sql.DataSource"
            username="jirauser"
            password="DBPASS"
            driverClassName="org.postgresql.Driver"
            url="jdbc:postgresql://localhost/jira"
           />
          <Resource name="UserTransaction" auth="Container" type="javax.transaction.UserTransaction"
            factory="org.objectweb.jotm.UserTransactionFactory" jotm.timeout="60"/>
          <Manager className="org.apache.catalina.session.PersistentManager" saveOnRestart="false"/>
        </Context>
.
w
q
doit

sudo sed -i "s/DBPASS/$dbpass/" /srv/jira/tomcat/conf/server.xml

# add missing libraries to Tomcat
sudo wget -O /tmp/jirajars.zip http://confluence.atlassian.com/download/attachments/200709089/jira-jars-tomcat6.zip?version=1
sudo unzip -d /tmp /tmp/jirajars.zip
sudo mv /tmp/jira-jars-tomcat6/*.jar /usr/share/tomcat6/lib

# fix tomcat memory settings
sudo sed -i '$a\CATALINA_OPTS="$CATALINA_OPTS -Dorg.apache.jasper.runtime.BodyContentImpl.LIMIT_BUFFER=true -Dmail.mime.decodeparameters=true -Xms128m -Xmx512m -XX:MaxPermSize=256m"' /srv/jira/tomcat/bin/setenv.sh

# build jira
sudo su - -c 'cd build;sh build.sh' jira
sudo su - -c "cp /srv/jira/build/dist-tomcat/tomcat-6/atlassian-jira-$jiraversion.war /srv/jira/tomcat/webapps/jira.war"

# start jira
sudo /etc/init.d/jira start
sudo update-rc.d jira defaults

#done
echo "JIRA installation complete. Open your browser and go to https://$servername/jira to complete the configuration"



