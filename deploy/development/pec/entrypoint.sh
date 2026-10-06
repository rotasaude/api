#!/bin/sh
# deploy/development/pec/entrypoint.sh
# Instala o PEC na primeira subida (modo treinamento, banco no serviço pec-db) e
# liga o HTTPS manual do manual oficial (APOIO/Certificado_Https_Linux) com o
# keystore de local/esusaps.p12. Depois só inicia.
set -eu

if [ ! -x /opt/e-SUS/webserver/standalone.sh ]; then
  java -jar "/pec/local/${PEC_JAR}" -console \
    -url="jdbc:postgresql://pec-db:5432/esus" -username=esus -password=esus -continue
  PGPASSWORD=esus psql -h pec-db -U esus -d esus -v ON_ERROR_STOP=1 \
    -c "update tb_config_sistema set ds_texto = null, ds_inteiro = 1 where co_config_sistema = 'TREINAMENTO';"
fi

CONF=/opt/e-SUS/webserver/config/application.properties
if [ -f /pec/local/esusaps.p12 ] && ! grep -q '^server.ssl.key-store=' "$CONF"; then
  cp /pec/local/esusaps.p12 /opt/e-SUS/webserver/config/esusaps.p12
  cat >> "$CONF" <<EOF
server.port=8443
server.ssl.key-store=config/esusaps.p12
server.ssl.key-store-password=${PEC_KEYSTORE_PASSWORD}
server.ssl.key-store-type=PKCS12
server.ssl.key-alias=esusaps
security.require-ssl=true
EOF
fi

exec /opt/e-SUS/webserver/standalone.sh
