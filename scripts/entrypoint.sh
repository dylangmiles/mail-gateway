#!/bin/bash

#
# can be done on every start...
#

# cleanup/remove amavis pidfile
rm -f /run/amavis/amavisd.pid 2> /dev/null > /dev/null

SMTPD_RECIPIENT_RESTRICTIONS="permit_mynetworks,reject"
AVAILABLE_NETWORKS="127.0.0.0/8"
if [ ! -z ${AUTO_TRUST_NETWORKS+x} ]; then
  AVAILABLE_NETWORKS=$(list-available-networks.sh | tr '\n' ',' | sed 's/,$//g')
  echo ">> trust all available networks: $AVAILABLE_NETWORKS"
fi

postconf -e "mynetworks=$AVAILABLE_NETWORKS"

if [ ! -z ${ADDITIONAL_MYNETWORKS+x} ]; then
  echo ">> update mynetworks to: $AVAILABLE_NETWORKS,$ADDITIONAL_MYNETWORKS"
  postconf -e "mynetworks=$AVAILABLE_NETWORKS,$ADDITIONAL_MYNETWORKS"
fi

if [ ! -z ${MYNETWORKS+x} ]; then
  if [ ! -z ${ADDITIONAL_MYNETWORKS+x} ]; then
    echo ">> Warning ADDITIONAL_MYNETWORKS will be ignored! only $MYNETWORKS will be set!"
  fi
  echo ">> update mynetworks to: $MYNETWORKS"
  postconf -e "mynetworks=$MYNETWORKS"
fi

# only on container creation
INITIALIZED="/.initialized"
if [ ! -f "$INITIALIZED" ]; then
	touch "$INITIALIZED"

  echo ">> cleaning old unused tls settings"
  sed -i 's/^smtp.*_tls_.*//g' /etc/postfix/main.cf

	if [ -z ${RELAYHOST+x} ]; then
    echo ">> it is advised to set a relayhost to avoid open relays..."
  else
    echo ">> setting relayhost to: $RELAYHOST"
    postconf -e "relayhost=$RELAYHOST"
  fi

  if [ -z ${MAIL_FQDN+x} ]; then
    MAIL_FQDN="amavis.mail-gateway"
  fi

  if echo "$MAIL_FQDN" | grep -v '\.'; then
    MAIL_FQDN="$MAIL_FQDN.local"
  fi
  MAIL_FQDN=$(echo "$MAIL_FQDN" | sed 's/[^.0-9a-z\-]//g')

  MAIL_NAME=$(echo "$MAIL_FQDN" | cut -d'.' -f1)
  MAILDOMAIN=$(echo "$MAIL_FQDN" | cut -d'.' -f2-)

  echo ">> set mail host to: $MAIL_FQDN"
  sed -i '12a\$myhostname = "'"$MAIL_FQDN"'";\' etc/amavis/conf.d/05-node_id
  echo "$MAIL_FQDN" > /etc/mailname
  echo "$MAIL_NAME" > /etc/hostname
  postconf -e "myhostname=$MAIL_FQDN"
  postconf -e "myorigin=$MAILDOMAIN"

  if [ -z ${POSTFIX_SMTPD_BANNER+x} ]; then
    POSTFIX_SMTPD_BANNER="$MAIL_FQDN ESMTP"
  fi
  echo ">> POSTFIX set smtpd_banner = $POSTFIX_SMTPD_BANNER"
  postconf -e "smtpd_banner=$POSTFIX_SMTPD_BANNER"
  
  ##
  # SPF enable
  ##
  if [ -z ${DISABLE_SPF_CHECKS+x} ]; then
    echo ">> POSTFIX enable spf policy check"

cat <<EOF >> /etc/postfix/master.cf
### enable spf policy  
policyd-spf  unix  -       n       n       -       0       spawn
    user=policyd-spf argv=/usr/sbin/postfix-policyd-spf-perl
EOF

  fi  

  if [ -z ${DISABLE_AMAVIS+x} ]; then
    echo ">> AMAVIS - enabling spam/virus scanning"

cat <<EOF >> /etc/postfix/main.cf
#ContentFilter:
content_filter = smtp-amavis:[127.0.0.1]:10024
receive_override_options = no_address_mappings
EOF

cat <<EOF >> /etc/postfix/master.cf
smtp-amavis  unix    -    -    n    -    2    smtp
 -o smtp_data_done_timeout=1200
 -o smtp_send_xforward_command=yes
 -o disable_dns_lookups=yes

127.0.0.1:10025 inet    n    -    n    -    -    smtpd
 -o content_filter=
 -o local_recipient_maps=
 -o relay_recipient_maps=
 -o smtpd_restriction_classes=
 -o smtpd_helo_restrictions=
 -o smtpd_sender_restrictions=
 -o smtpd_recipient_restrictions=permit_mynetworks,reject
 -o mynetworks=127.0.0.0/8
 -o strict_rfc821_envelopes=yes
 -o smtpd_error_sleep_time=0
 -o smtpd_soft_error_limit=1001
 -o smtpd_hard_error_limit=1000
 -o receive_override_options=no_header_body_checks
 -o smtp_tls_security_level=none
EOF

    echo 'use strict;' > /etc/amavis/conf.d/15-content_filter_mode

    if [ -z ${DISABLE_VIRUS_CHECKS+x} ]; then
     echo '@bypass_virus_checks_maps = (' >> /etc/amavis/conf.d/15-content_filter_mode
     echo '    \%bypass_virus_checks, \@bypass_virus_checks_acl, \$bypass_virus_checks_re);' >> /etc/amavis/conf.d/15-content_filter_mode
    fi

    if [ -z ${DISABLE_SPAM_CHECKS+x} ]; then
     echo '@bypass_spam_checks_maps = (' >> /etc/amavis/conf.d/15-content_filter_mode
     echo '    \%bypass_spam_checks, \@bypass_spam_checks_acl, \$bypass_spam_checks_re);' >> /etc/amavis/conf.d/15-content_filter_mode
    fi

    echo '1;  # ensure a defined return' >> /etc/amavis/conf.d/15-content_filter_mode

    echo ">> AMAVIS - modify settings"

    if [ -z ${AMAVIS_SA_TAG_LEVEL_DEFLT+x} ]; then
      AMAVIS_SA_TAG_LEVEL_DEFLT="undef"
    fi

    if [ -z ${AMAVIS_SA_TAG2_LEVEL_DEFLT+x} ]; then
      AMAVIS_SA_TAG2_LEVEL_DEFLT="5"
    fi

    if [ -z ${AMAVIS_SA_KILL_LEVEL_DEFLT+x} ]; then
      AMAVIS_SA_KILL_LEVEL_DEFLT="20"
    fi

    echo "    sa_tag_level_deflt  = $AMAVIS_SA_TAG_LEVEL_DEFLT;"
    echo "    sa_tag2_level_deflt  = $AMAVIS_SA_TAG2_LEVEL_DEFLT;"
    echo "    sa_kill_level_deflt  = $AMAVIS_SA_KILL_LEVEL_DEFLT;"

    sed -i -e 's/sa_tag_level_deflt.*/sa_tag_level_deflt = '"$AMAVIS_SA_TAG_LEVEL_DEFLT"';/g' /etc/amavis/conf.d/20-debian_defaults
    sed -i -e 's/sa_tag2_level_deflt.*/sa_tag2_level_deflt = '"$AMAVIS_SA_TAG2_LEVEL_DEFLT"';/g' /etc/amavis/conf.d/20-debian_defaults
    sed -i -e 's/sa_kill_level_deflt.*/sa_kill_level_deflt = '"$AMAVIS_SA_KILL_LEVEL_DEFLT"';/g' /etc/amavis/conf.d/20-debian_defaults
  fi

  if [ -z ${POSTFIX_SSL_OUT_CERT+x} ]; then
    POSTFIX_SSL_OUT_CERT="/etc/postfix/tls/client.crt"
  fi

  if [ -z ${POSTFIX_SSL_OUT_KEY+x} ]; then
    POSTFIX_SSL_OUT_KEY="/etc/postfix/tls/client.key"
  fi

  if [ -z ${POSTFIX_SSL_OUT_SECURITY_LEVEL+x} ]; then
    POSTFIX_SSL_OUT_SECURITY_LEVEL="may"
  fi

  if [[ -f "$POSTFIX_SSL_OUT_CERT" && -f "$POSTFIX_SSL_OUT_KEY" ]]; then
    echo ">> POSTFIX SSL - enabling outgoing SSL"
cat <<EOF >> /etc/postfix/main.cf
##### TLS settings ######

### outgoing connections ###
# smtp_tls_security_level=encrypt # for secure connections only
smtp_tls_security_level=$POSTFIX_SSL_OUT_SECURITY_LEVEL
smtp_tls_cert_file=$POSTFIX_SSL_OUT_CERT
smtp_tls_key_file=$POSTFIX_SSL_OUT_KEY

smtp_tls_exclude_ciphers = aNULL, DES, RC4, MD5, 3DES
smtp_tls_mandatory_exclude_ciphers = aNULL, DES, RC4, MD5, 3DES
smtp_tls_protocols = !SSLv2 !SSLv3
smtp_tls_mandatory_protocols = !SSLv2, !SSLv3
smtp_tls_mandatory_ciphers=high

smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtp_tls_loglevel = 1
EOF
  fi

  if [ -z ${POSTFIX_SSL_IN_CERT+x} ]; then
    POSTFIX_SSL_IN_CERT="/etc/postfix/tls/server.crt"
  fi

  if [ -z ${POSTFIX_SSL_IN_KEY+x} ]; then
    POSTFIX_SSL_IN_KEY="/etc/postfix/tls/server.key"
  fi

  if [ -z ${POSTFIX_SSL_IN_SECURITY_LEVEL+x} ]; then
    POSTFIX_SSL_IN_SECURITY_LEVEL="may"
  fi

  if [[ -f "$POSTFIX_SSL_IN_CERT" && -f "$POSTFIX_SSL_IN_KEY" ]]; then
    echo ">> POSTFIX SSL - enabling incoming SSL"
    
cat <<EOF >> /etc/postfix/master.cf
### enable port 587 submissions ###
submission inet n - - - - smtpd
EOF

    
cat <<EOF >> /etc/postfix/main.cf
### incoming connections ###
# smtpd_tls_security_level=encrypt # for secure connections only
smtpd_tls_security_level=$POSTFIX_SSL_IN_SECURITY_LEVEL
smtpd_tls_cert_file=$POSTFIX_SSL_IN_CERT
smtpd_tls_key_file=$POSTFIX_SSL_IN_KEY

smtpd_tls_exclude_ciphers = aNULL, DES, RC4, MD5, 3DES
smtpd_tls_mandatory_exclude_ciphers = aNULL, DES, RC4, MD5, 3DES
smtpd_tls_protocols = !SSLv2 !SSLv3
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3
smtpd_tls_mandatory_ciphers=high

smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtpd_tls_loglevel = 1
EOF
  fi

  if [ -f /etc/postfix/tls/rootCA.crt ]; then
    echo ">> POSTFIX SSL - enabling CA based Client Authentication"
    postconf -e smtpd_tls_ask_ccert=yes
    postconf -e smtpd_tls_CAfile=/etc/postfix/tls/rootCA.crt 
    SMTPD_RECIPIENT_RESTRICTIONS="smtpd_recipient_restrictions=permit_mynetworks,permit_tls_all_clientcerts,reject_unauth_destination"
    
  fi

  if [ ! -z ${POSTFIX_SSL_IN_CERT_FINGERPRINTS+x} ] || [ -f /etc/postfix/tls/relay_clientcerts ]; then
    echo ">> POSTFIX SSL - enabling Fingerprint based Client Authentication"
    if [ ! -z ${POSTFIX_SSL_IN_CERT_FINGERPRINTS+x} ]; then
      echo "$POSTFIX_SSL_IN_CERT_FINGERPRINTS" >> /etc/postfix/tls/relay_clientcerts
    fi
    postmap /etc/postfix/tls/relay_clientcerts
    postconf -e smtpd_tls_ask_ccert=yes
    postconf -e relay_clientcerts=hash:/etc/postfix/tls/relay_clientcerts
    SMTPD_RECIPIENT_RESTRICTIONS="smtpd_recipient_restrictions=permit_mynetworks,permit_tls_all_clientcerts,reject_unauth_destination"
  fi

  if [ -f /etc/postfix/tls/dh1024.pem ]; then
    echo ">> using dh1024.pem provided in volume"
    postconf -e 'smtpd_tls_dh1024_param_file=/etc/postfix/tls/dh1024.pem'
  fi

  if [ -f /etc/postfix/tls/dh512.pem ]; then
    echo ">> using dh512.pem provided in volume"
    postconf -e 'smtpd_tls_dh512_param_file=/etc/postfix/tls/dh512.pem'
  fi

  if [ ! -z ${POSTFIX_QUEUE_LIFETIME_BOUNCE+x} ]; then
    echo ">> POSTFIX set bounce_queue_lifetime = $POSTFIX_QUEUE_LIFETIME_BOUNCE"
    postconf -e "bounce_queue_lifetime=$POSTFIX_QUEUE_LIFETIME_BOUNCE"
  fi

  if [ ! -z ${POSTFIX_QUEUE_LIFETIME_MAX+x} ]; then
    echo ">> POSTFIX set maximal_queue_lifetime = $POSTFIX_QUEUE_LIFETIME_MAX"
    postconf -e "maximal_queue_lifetime=$POSTFIX_QUEUE_LIFETIME_MAX"
  fi

  if [ ! -z ${POSTFIX_MYDESTINATION+x} ]; then
    echo ">> POSTFIX set mydestination = $POSTFIX_MYDESTINATION"
    postconf -e "mydestination=$POSTFIX_MYDESTINATION"
  fi

  if [ ! -z ${POSTFIX_RELAY_DOMAINS+x} ]; then
    echo ">> POSTFIX set relay_domains = $POSTFIX_RELAY_DOMAINS"
    postconf -e "relay_domains=$POSTFIX_RELAY_DOMAINS"
    postconf -e "parent_domain_matches_subdomains = debug_peer_list smtpd_access_maps"
  fi

  if [ -d /etc/postfix/additional/opendkim ]; then
    echo ">> enabling DKIM"
    dkim-helper.sh
  fi

  if [ -f /etc/postfix/additional/transport ]; then
    echo ">> POSTFIX found 'additional/transport' activating it as transport_maps"
    postmap /etc/postfix/additional/transport
    postconf -e "transport_maps = hash:/etc/postfix/additional/transport"
  fi
  
  if [ -f /etc/postfix/additional/sasl_passwords ]; then
    echo ">> POSTFIX found 'additional/sasl_passwords' activating it as sasl_passwords"
    postmap /etc/postfix/additional/sasl_passwords
    
    postconf -e "smtp_use_tls=yes"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_security_options ="
    
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/additional/sasl_passwords"
  fi
  
  
   if [ -f /etc/postfix/additional/virtual ]; then
    echo ">> POSTFIX found 'additional/virtual' activating it as virtual"
    postmap /etc/postfix/additional/virtual
    
    postconf -e "virtual_alias_maps = hash:/etc/postfix/additional/virtual"
  fi

  if [ -f /etc/postfix/additional/header_checks ]; then
    echo ">> POSTFIX found 'additional/header_checks' activating it as header_checks"
    postconf -e "header_checks = regexp:/etc/postfix/additional/header_checks"
  fi
 
  if [ -f /etc/postfix/additional/stunnel ]; then
    echo ">> STUNNEL found 'additional/stunnel' copy to /etc/ssl/stunnel/stunnel.conf"
    mkdir -p /etc/ssl/stunnel
    cat /etc/postfix/additional/stunnel >> /etc/ssl/stunnel/stunnel.conf
  fi
  
  if [ -f /etc/postfix/additional/amavis-50-user ]; then
    echo ">> AMAVIS found 'additional/amavis-50-user' activating it /etc/amavis/conf.d/50-user"
    
    cp -f /etc/postfix/additional/amavis-50-user  /etc/amavis/conf.d/50-user
    
  fi 
  
  if [ -f /etc/postfix/additional/sender_access ]; then
    echo ">> POSTFIX found 'additional/sender_access' activating it as sender_access"
    postmap /etc/postfix/additional/sender_access
    
    SMTPD_RECIPIENT_RESTRICTIONS="$SMTPD_RECIPIENT_RESTRICTIONS,check_sender_access hash:/etc/postfix/additional/sender_access"
  fi
  
 

  ##
  # POSTFIX RAW Config ENVs
  ##
  if env | grep '^POSTFIX_RAW_CONFIG_'
  then
    echo -e "\n## POSTFIX_RAW_CONFIG ##\n" >> /etc/postfix/main.cf
    env | grep '^POSTFIX_RAW_CONFIG_' | while read I_CONF
    do
      CONFD_CONF_NAME=$(echo "$I_CONF" | cut -d'=' -f1 | sed 's/POSTFIX_RAW_CONFIG_//g' | tr '[:upper:]' '[:lower:]')
      CONFD_CONF_VALUE=$(echo "$I_CONF" | sed 's/^[^=]*=//g')

      echo "$CONFD_CONF_NAME = $CONFD_CONF_VALUE" >> /etc/postfix/main.cf
    done
    
    echo >> /etc/postfix/main.cf
    
  fi
  
  
  ## Postgrey
  if [ -z ${DISABLE_POSTGREY+x} ]; then
    echo ">> POSTGREY add post grey into receipient restrictions." 
    SMTPD_RECIPIENT_RESTRICTIONS="$SMTPD_RECIPIENT_RESTRICTIONS,check_policy_service inet:127.0.0.1:10023"
  fi
  
    
  
  
  ##
  # SPF restrictions
  # Need to do this after setting other recipient restrictions.
  ##
  if [ -z ${DISABLE_SPF_CHECKS+x} ]; then
    echo ">> POSTFIX add spf check to recipient restrictions."
    postconf -e policyd-spf_time_limit=3600
    SMTPD_RECIPIENT_RESTRICTIONS="$SMTPD_RECIPIENT_RESTRICTIONS,check_policy_service unix:private/policyd-spf"
  fi
  
  
  ##
  # Black lists
  ##
  if [ -z ${DISABLE_BLACKLISTSx} ]; then
    echo ">> POSTFIX black list check to recipient restrictions."
    SMTPD_RECIPIENT_RESTRICTIONS="$SMTPD_RECIPIENT_RESTRICTIONS,reject_rbl_client sbl-xbl.spamhaus.org"
  fi
  
  #
  # Permit at the end
  #
  SMTPD_RECIPIENT_RESTRICTIONS="$SMTPD_RECIPIENT_RESTRICTIONS,permit"

  postconf -e "$SMTPD_RECIPIENT_RESTRICTIONS"
  
  
  
  #
  # RUNIT
  #
  POSTGREYCMD='#!/bin/sh\nexec /usr/sbin/postgrey --inet=127.0.0.1:10023 --delay=60'
  if [ -f /etc/postfix/additional/postgrey_whitelist_clients ]; then
    echo ">> POSTGREY found 'additional/postgrey_whitelist_clients' activating it as postgrey_whitelist_clients"
    
    POSTGREYCMD="$POSTGREYCMD --whitelist-clients=/etc/postfix/additional/postgrey_whitelist_clients"
    
  fi

  echo ">> RUNIT - create services"
  mkdir -p /etc/sv/rsyslog /etc/sv/postfix /etc/sv/opendkim /etc/sv/amavis /etc/sv/clamd /etc/sv/freshclam /etc/sv/stunnel /etc/sv/postgrey
  echo -e '#!/bin/sh\nexec /usr/sbin/rsyslogd -n' > /etc/sv/rsyslog/run
    echo -e '#!/bin/sh\nrm /var/run/rsyslogd.pid' > /etc/sv/rsyslog/finish
  echo -e '#!/bin/sh\nexec  /usr/sbin/opendkim -f -x /etc/opendkim.conf -u opendkim -P /var/run/opendkim/opendkim.pid -p inet:8891@localhost | logger -t opendkim' > /etc/sv/opendkim/run
  echo -e '#!/bin/sh\nexec /usr/sbin/amavisd-new foreground | logger -t amavisd-new' > /etc/sv/amavis/run
    echo -e '#!/bin/sh\nrm -f /run/amavis/amavisd.pid' > /etc/sv/amavis/finish
  echo -e '#!/bin/sh\nservice postfix start; sleep 5; while ps aux | grep [p]ostfix | grep [m]aster > /dev/null 2> /dev/null; do sleep 5; done' > /etc/sv/postfix/run
    echo -e '#!/bin/sh\nservice postfix stop' > /etc/sv/postfix/finish
  echo -e '#!/bin/sh\nexec /usr/sbin/clamd --foreground=true | logger -t clamd' > /etc/sv/clamd/run
  echo -e '#!/bin/sh\nexec freshclam -d --foreground=true | logger -t freshclam' > /etc/sv/freshclam/run
  echo -e '#!/bin/sh\nexec stunnel /etc/ssl/stunnel/stunnel.conf | logger -t stunnel' > /etc/sv/stunnel/run
    echo -e '#!/bin/sh\nrm /var/run/stunnel.pid' > /etc/sv/stunnel/finish
  echo -e $POSTGREYCMD > /etc/sv/postgrey/run
    
  chmod a+x /etc/sv/*/run /etc/sv/*/finish

  echo ">> RUNIT - enable services"
  
  if [ -f /etc/postfix/additional/stunnel ]; then
    ln -s /etc/sv/stunnel /etc/service/stunnel
  fi
  
  ln -s /etc/sv/postfix /etc/service/postfix
  ln -s /etc/sv/rsyslog /etc/service/rsyslog

  if [ -d /etc/postfix/additional/opendkim ]; then
    ln -s /etc/sv/opendkim /etc/service/opendkim
  fi

  if [ -z ${DISABLE_AMAVIS+x} ]; then
    ln -s /etc/sv/amavis /etc/service/amavis

    if [ -z ${DISABLE_VIRUS_CHECKS+x} ]; then
      ln -s /etc/sv/clamd /etc/service/clamd
      ln -s /etc/sv/freshclam /etc/service/freshclam
    fi
  fi
  
  if [ -z ${DISABLE_POSTGREY+x} ]; then
    ln -s /etc/sv/postgrey /etc/service/postgrey
  fi

fi

exec runsvdir -P /etc/service
