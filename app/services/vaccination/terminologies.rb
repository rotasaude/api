# Terminologias do LEDI/RNDS (config/vaccination/rnds_terminologies.yml).
# `list` devolve [{ code:, name: }] (V14); `rnds_code` quando o código RNDS difere.
module Vaccination
  module Terminologies
    KINDS = %w[dose strategy route site care_group maternal_condition].freeze

    module_function

    # Só os ativos: o que se oferece para dose nova. `valid?`/`name` aceitam também os inativos (leitura e transcrição antiga).
    def list(kind) = items(kind).select { |item| item["active"] != false }.map { |item| { code: item["code"], name: item["name"] } }
    def active?(kind, code) = valid?(kind, code) && index(kind).dig(code.to_s, "active") != false
    def valid?(kind, code) = KINDS.include?(kind.to_s) && index(kind).key?(code.to_s)
    def name(kind, code) = index(kind).dig(code.to_s, "name")
    def rnds_code(kind, code) = index(kind).dig(code.to_s, "rnds_code") || (code.to_s if valid?(kind, code))

    def items(kind)
      raise ArgumentError, "unknown terminology: #{kind}" unless KINDS.include?(kind.to_s)

      YamlFiles.load("rnds_terminologies").fetch(kind.to_s).fetch("items")
    end

    def index(kind)
      return {} unless KINDS.include?(kind.to_s)

      (@index ||= Concurrent::Map.new).compute_if_absent(kind.to_s) { items(kind).index_by { |item| item["code"] }.freeze }
    end
    private_class_method :items, :index
  end
end
