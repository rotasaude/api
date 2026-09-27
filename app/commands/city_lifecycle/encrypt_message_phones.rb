# Cifra o telefone das mensagens gravadas antes de `encrypts` nas colunas de
# telefone — InboundMessage#from e OutboundMessage#to (api#19, fechamento do
# módulo 07; ADR-0013). A migração de schema roda sem a chave da cidade, por
# isso isto é um comando, rodado DENTRO da cidade (CityConnection.with, via
# city:encrypt_message_phones).
#
# Não dá para ler a linha pelo modelo: com support_unencrypted_data desligado
# (produção), o texto claro levanta ao decifrar. Lemos a coluna crua, ciframos
# com o tipo do próprio atributo (chave determinística da cidade corrente) e
# regravamos por SQL. Linha já cifrada fica como está: idempotente.
module CityLifecycle
  module EncryptMessagePhones
    TARGETS = [ [ InboundMessage, :from ], [ OutboundMessage, :to ] ].freeze
    BATCH_SIZE = 500

    # Devolve quantas linhas foram cifradas por modelo, ex.:
    # { "InboundMessage" => 3, "OutboundMessage" => 0 }.
    def self.call
      raise CityEncryption::MissingKey, "sem cidade corrente: a chave do telefone é a da cidade" if Current.city.nil?

      TARGETS.to_h { |model, attribute| [ model.name, encrypt_column(model, attribute) ] }
    end

    def self.encrypt_column(model, attribute)
      type = model.type_for_attribute(attribute)
      encryptor = ActiveRecord::Encryption.encryptor
      conn = model.connection
      column = conn.quote_column_name(attribute)
      changed = 0

      model.in_batches(of: BATCH_SIZE) do |batch|
        conn.select_rows(batch.select(:id, attribute).to_sql).each do |id, stored|
          next if stored.nil? || encryptor.encrypted?(stored)

          conn.exec_update(
            model.sanitize_sql(["UPDATE #{model.quoted_table_name} SET #{column} = ? WHERE id = ?", type.serialize(stored), id])
          )
          changed += 1
        end
      end

      changed
    end
    private_class_method :encrypt_column
  end
end
