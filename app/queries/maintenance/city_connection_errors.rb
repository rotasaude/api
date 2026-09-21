# O que conta como "a cidade não respondeu" na API de manutenção — leitura e
# escrita. Só estas classes publicam a mensagem (redigida por
# CitySchema.redact): é ela que diz QUAL host e banco falharam, e ela traz a
# URL com a senha do role. Qualquer outra exceção é texto sem controle (um bug
# pode interpolar dado de cidadão) e sai só pelo nome da classe.
module Maintenance
  module CityConnectionErrors
    CLASSES = [
      ActiveRecord::ConnectionNotEstablished,
      ActiveRecord::ConnectionTimeoutError,
      PG::ConnectionBad,
      CityConnection::InvalidCityDatabase
    ].freeze
  end
end
