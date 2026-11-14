# Esquemas do contrato field-sync-v1 (módulo 24b, ADR 0052; contrato §9.4):
# cópia de rotasaude/contracts/field-sync/ em config/field_sync/, presa por
# SHA-256. O arquivo que não bate não carrega (falha fechada). Usado nos specs
# (respostas da sessão, do envio e do download) e em execução (preflight 1.16:
# o envelope do envio contra o esquema raiz e cada item contra
# `#/$defs/item`, Task 20). Os erros saem só com ponteiro e palavra-chave do
# esquema, nunca com o valor (o corpo traz pessoa, motivo e medida).
#
# Os SHA são os da v1.2.0 (módulo 24c, ADR 0053): commit 1012666 do
# rotasaude/contracts, com o esquema novo da referência offline
# (reference-response-v1).
module FieldSync
  module Schemas
    DIR = Rails.root.join("config/field_sync")
    SHA256 = {
      "session-response-v1" => "b3615de707cc235457b2c94a62823f332c244a700a1c6444144f204bb82eb6fc",
      "upload-request-v1" => "c971a785ceabd27602ee92765c656443b8d9e803c59c90bfb9c9b4e7d40c0284",
      "upload-response-v1" => "4c9c04191030504bb13749bf57261d749f03e4c8782bc0f26a1edca1bf7cedb9",
      "changes-response-v1" => "8c19be1cb7f72c98ff488acb1749daec0e1eba03efb99ec47640efd576c31882",
      "reference-response-v1" => "484e0aabe3f3a3ff6e71fcae32c5f98ec5d36331cae7521ce97b03ad094f0a36",
      "domains-v1" => "554d5b2353a26c19c2ae8a6be50055c04743be0d4fb39f24a790f5386f96c547"
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
