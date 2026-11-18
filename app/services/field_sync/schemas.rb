# Esquemas do contrato field-sync-v1 (módulo 24b, ADR 0052; contrato §9.4):
# cópia de rotasaude/contracts/field-sync/ em config/field_sync/, presa por
# SHA-256. O arquivo que não bate não carrega (falha fechada). Usado nos specs
# (respostas da sessão, do envio e do download) e em execução (preflight 1.16:
# o envelope do envio contra o esquema raiz e cada item contra
# `#/$defs/item`, Task 20). Os erros saem só com ponteiro e palavra-chave do
# esquema, nunca com o valor (o corpo traz pessoa, motivo e medida).
#
# Os SHA são os da v1.3.0 do rotasaude/contracts (módulo 35a, ADR 0054; §13),
# ainda sem tag: o worktree contracts-mod35a no commit 2b1c24c. A Task 18 do
# plano do api prende os da tag field-sync-v1.3.0.
module FieldSync
  module Schemas
    DIR = Rails.root.join("config/field_sync")
    SHA256 = {
      "session-response-v1" => "ab8b9778841b8c1dea6215b794c2e85b6a0fb6093a74dccd6e12fd5d617d8c74",
      "upload-request-v1" => "5fa0c171be285754c9a1e237eafdbc61b467edd6af9f026efb2552f8b96024e3",
      "upload-response-v1" => "ae211029fda7662b29658f6e94df1cba5c01275db2e98ecc870ebfc50f2337aa",
      "changes-response-v1" => "980a9992ebb549094260a1d02d3daea237ce0e0e1b63d892391600832d66c40b",
      "reference-response-v1" => "d2db3e6ebe806210d15f872ee2012db2db7902acaee25ee25bf028b33d26890e",
      "domains-v1" => "d8b92593e29c72c36c96b64ade69d9e8f8663456bc7f5328cf4c20a9263d6038"
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
