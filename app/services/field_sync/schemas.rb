# Esquemas do contrato field-sync-v1 (módulo 24b, ADR 0052; contrato §9.4):
# cópia de rotasaude/contracts/field-sync/ em config/field_sync/, presa por
# SHA-256. O arquivo que não bate não carrega (falha fechada). Usado nos specs
# (respostas da sessão, do envio e do download) e em execução (preflight 1.16:
# o envelope do envio contra o esquema raiz e cada item contra
# `#/$defs/item`, Task 20). Os erros saem só com ponteiro e palavra-chave do
# esquema, nunca com o valor (o corpo traz pessoa, motivo e medida).
#
# Os SHA são os do commit caebe8d do contracts (a tag field-sync-v1.0.0 ainda
# não saiu, C-HOLD); a Task 26 re-prende na tag.
module FieldSync
  module Schemas
    DIR = Rails.root.join("config/field_sync")
    SHA256 = {
      "session-response-v1" => "199957bcf5b9d16645cf1a05e9cbbb210001474556a6ab3104783f49a1660bb0",
      "upload-request-v1" => "a372ebf5b53a1812d18efc2e29c735807f8cd62a5071540ba9f83363657e3e6f",
      "upload-response-v1" => "35d20235d47d68833b9106a25ef8fcdcadbf5457e607916c2e26e2cb02b437cd",
      "changes-response-v1" => "baa2022a2661a2eb928133912e0eebc7d820d9a2fcfa6cba43a437098effc022",
      "domains-v1" => "3c20b8b5374e5a855742d67365f68059bcad6a558e398821fe182fc52c81759e"
    }.freeze

    class Tampered < StandardError; end

    # Só ponteiros e palavras-chave (`errors`: [{ pointer:, type: }]).
    class Invalid < StandardError
      attr_reader :errors

      def initialize(name, errors)
        @errors = errors
        super("#{name}: #{errors.map { |error| "#{error[:pointer].presence || '(root)'} #{error[:type]}" }.join(' | ')}")
      end
    end

    @cache = {}
    @lock = Mutex.new

    module_function

    # [{ pointer: "/items/0/body/occurred_at", type: "pattern" }, …]; [] se válido.
    # `ref:` valida contra um $defs do esquema (ex.: "#/$defs/item").
    def errors(name, payload, ref: nil)
      schemer(name, ref).validate(payload).map { |error| { pointer: error.fetch("data_pointer"), type: error.fetch("type") } }.uniq
    end

    def valid?(name, payload, ref: nil) = schemer(name, ref).valid?(payload)

    def validate!(name, payload, ref: nil)
      found = errors(name, payload, ref: ref)
      raise Invalid.new(name, found) if found.any?

      true
    end

    # O domains-v1.json (dado, não esquema).
    def domains = cached([ :document, "domains-v1" ]) { load_document("domains-v1") }

    def schemer(name, ref)
      root = cached([ :schemer, name ]) { JSONSchemer.schema(load_document(name)) }
      ref ? cached([ :ref, name, ref ]) { root.ref(ref) } : root
    end

    def cached(key)
      @lock.synchronize { @cache[key] ||= yield }
    end

    def load_document(name)
      expected = SHA256.fetch(name)
      raw = File.binread(DIR.join("#{name}.json"))
      raise Tampered, "#{name}.json não bate com o SHA-256 preso" unless Digest::SHA256.hexdigest(raw) == expected

      JSON.parse(raw).freeze
    end
    private_class_method :schemer, :cached, :load_document
  end
end
