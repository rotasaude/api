# Esquemas do contrato field-sync-v1 (módulo 24b, ADR 0052; contrato §9.4):
# cópia de rotasaude/contracts/field-sync/ em config/field_sync/, presa por
# SHA-256. O arquivo que não bate não carrega (falha fechada). Usado nos specs
# (respostas da sessão, do envio e do download) e em execução (preflight 1.16:
# o envelope do envio contra o esquema raiz e cada item contra
# `#/$defs/item`, Task 20). Os erros saem só com ponteiro e palavra-chave do
# esquema, nunca com o valor (o corpo traz pessoa, motivo e medida).
#
# Os SHA são os da tag field-sync-v1.1.0 do rotasaude/contracts (Q67:
# too_many_requests em errors.item do domains; os outros quatro inalterados).
module FieldSync
  module Schemas
    DIR = Rails.root.join("config/field_sync")
    SHA256 = {
      "session-response-v1" => "199957bcf5b9d16645cf1a05e9cbbb210001474556a6ab3104783f49a1660bb0",
      "upload-request-v1" => "a372ebf5b53a1812d18efc2e29c735807f8cd62a5071540ba9f83363657e3e6f",
      "upload-response-v1" => "820bf2a8fb1fc8bb718141c6adc4663be01eda84450471fa142811fe27ce77de",
      "changes-response-v1" => "baa2022a2661a2eb928133912e0eebc7d820d9a2fcfa6cba43a437098effc022",
      "domains-v1" => "8395db02ae26d7424f2a661429c209abfc8dd37594d12056aa767a915e57d4b1"
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

    # Como `errors`, mais o lugar no esquema (`schema_pointer`) e, no
    # `required`, as chaves que faltam (nomes do esquema, nunca valor): o envio
    # do app monta o `path` da Q32/Q46 com eles (Task 20).
    def failures(name, payload, ref: nil)
      schemer(name, ref).validate(payload).map do |error|
        { pointer: error.fetch("data_pointer"), type: error.fetch("type"), schema_pointer: error["schema_pointer"].to_s,
          missing: Array(error.dig("details", "missing_keys")).map(&:to_s) }
      end.uniq
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
