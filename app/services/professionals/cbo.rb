# Lista CBO da saúde versionada no api (ADR 0021): carregada uma vez por
# processo. Acrescentar ocupação é um commit, sem migração.
module Professionals
  module Cbo
    Entry = Data.define(:code, :title, :council, :deprecated)
    PATH = Rails.root.join("config/professionals/cbo_saude.yml")

    class << self
      def all
        @all ||= YAML.load_file(PATH).map do |row|
          Entry.new(code: row.fetch("code").to_s, title: row.fetch("title"), council: row["council"],
                    deprecated: row.fetch("deprecated", false))
        end.freeze
      end

      def active = all.reject(&:deprecated)

      def find(code) = all.find { |e| e.code == code.to_s }
    end
  end
end
