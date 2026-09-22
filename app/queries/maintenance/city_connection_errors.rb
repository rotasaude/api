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
      # Conexão que cai NO MEIO de uma query (não ao tentar abrir) — o adapter
      # de Postgres do Rails 8.1 (translate_exception) a levanta como
      # ConnectionFailed (< QueryAborted < StatementInvalid), não como
      # ConnectionNotEstablished. StatementInvalid/QueryCanceled continuam de
      # fora (cobrem qualquer erro de SQL/timeout de consulta, não só de
      # conexão) — só esta subclasse específica entra.
      ActiveRecord::ConnectionFailed,
      # Defensiva: o adapter normalmente já embrulha PG::ConnectionBad em
      # ConnectionNotEstablished/ConnectionFailed (translate_exception), mas
      # um PG::ConnectionBad cru pode escapar (por exemplo, ao registrar o
      # pool, antes do adapter existir) — fica na lista para esse caso.
      PG::ConnectionBad,
      CityConnection::InvalidCityDatabase
    ].freeze
  end
end
