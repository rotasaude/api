# Esquemas do contrato field-sync-v1 (módulo 24b, ADR 0052; contrato §9.4):
# cópia de rotasaude/contracts/field-sync/ em config/field_sync/, presa por
# SHA-256. O arquivo que não bate não carrega (falha fechada). Usado nos specs
# (respostas da sessão, do envio e do download) e em execução (preflight 1.16:
# o envelope do envio contra o esquema raiz e cada item contra
# `#/$defs/item`, Task 20). Os erros saem só com ponteiro e palavra-chave do
# esquema, nunca com o valor (o corpo traz pessoa, motivo e medida).
#
# Os SHA são os da v1.4.0 do rotasaude/contracts (módulo 35b, ADR 0054; §11),
# no commit 15379c1, ainda sem tag; a Task 20 prende os da tag
# field-sync-v1.4.0. A v1.3.0 (tag de 2026-11-18, contracts c022e80) segue
# aceita: nada do pedido dela passou a ser recusado.
module FieldSync
  module Schemas
    DIR = Rails.root.join("config/field_sync")
    SHA256 = {
      "session-response-v1" => "0ecca17934764f012c92f8a2d2f2092a77174867402b4e92c24879a48343e6b9",
      "upload-request-v1" => "1e22ad13bfe061e1aba5b7874d849a451426269974ce99efee5d0ea1319945e9",
      "upload-response-v1" => "04d30d759f88d1caafcb6a5ef37f3af2cc75695ef721e5a306d541e5967565a3",
      "changes-response-v1" => "5154ae0f90b4537fb02a38b1a8d7853991874516dd1dd25834fae29feb36796b",
      "reference-response-v1" => "13e3eb16e2606b8085751e8c930660145732df49a5cef5dba6a28291a1edc29a",
      "domains-v1" => "4346776b7aaee1e8cbfece2228a3fe93a38891533525ccf4f85d2d91a58f7e1b"
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
