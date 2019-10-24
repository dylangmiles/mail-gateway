FROM debian:jessie

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get -q -y update \
 && apt-get -q -y install runit \
                          telnet \
                          net-tools \
                          postfix \
                          rsyslog \
                          clamav clamav-daemon amavisd-new spamassassin \
                          arj bzip2 cabextract cpio file gzip nomarch pax unzip zoo zip zoo \
                          \
                          libnet-dns-perl libmail-spf-perl postfix-policyd-spf-perl \
                          razor pyzor\
                          \
                          opendkim \
                          opendkim-tools \
                          \
                          postgrey \
                          \
                          stunnel \
                          \
 && apt-get -q -y clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
 \
 && head -n $(grep -n RULES /etc/rsyslog.conf | cut -d':' -f1) /etc/rsyslog.conf > /etc/rsyslog.conf.new \
 && mv /etc/rsyslog.conf.new /etc/rsyslog.conf \
 && echo '*.*        /dev/stdout' >> /etc/rsyslog.conf \
 && sed -i '/imklog.so/d' /etc/rsyslog.conf \
 \
 && adduser clamav amavis

#
# Postfix
#

RUN openssl dhparam -out /etc/postfix/dh1024.pem 1024 \
 && postconf -e 'smtpd_tls_dh1024_param_file=/etc/postfix/dh1024.pem' \
 && openssl dhparam -out /etc/postfix/dh512.pem 512 \
 && postconf -e 'smtpd_tls_dh512_param_file=/etc/postfix/dh512.pem'

#
# ClamAV
#

RUN service clamav-daemon stop
RUN freshclam
RUN service clamav-daemon start

#
# razor & pyzor
#

RUN su - amavis -s /bin/bash -c 'razor-admin -create; razor-admin -register; pyzor discover'


#
# postgreay configuration
#
#RUN echo 'POSTGREY_OPTS="--inet=10023 --delay=60"' >> /etc/default/postgrey


#
# Relay Configuration
#

RUN postconf -e 'mydestination=localhost, localhost.localdomain, localhost' \
 && postconf -e 'smtpd_relay_restrictions=' \
 && postconf -e 'smtpd_recipient_restrictions=permit_mynetworks reject_unauth_destination' \
 \
 && postconf -e 'mydestination=' \
 && postconf -e 'local_recipient_maps=' \
 && postconf -e 'local_transport = error:local mail delivery is disabled'

COPY scripts /usr/local/bin

VOLUME ["/etc/postfix/tls", "/etc/postfix/additional"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
