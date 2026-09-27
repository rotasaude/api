# Catálogo CBO da saúde (spec 2026-09-27-module-10-professionals-design.md
# §3.4). Carrega config/professionals/cbo_saude.yml uma vez. MÍNIMO: só
# find/active/council_for para desbloquear a renderização de vínculo
# (ProfessionalRendering#link_json), que já referenciava esta classe sem que
# ela existisse — a lista CBO completa é entrega da fatia 2.
module Professionals
  class Cbo
    Entry = Struct.new(:code, :title, :council, :deprecated, keyword_init: true) do
      def deprecated? = !!deprecated
    end

    class << self
      def all
        @all ||= YAML.load_file(Rails.root.join("config/professionals/cbo_saude.yml")).map do |h|
          Entry.new(**h.symbolize_keys)
        end
      end

      def find(code) = all.find { |e| e.code == code }

      def active = all.reject(&:deprecated?)

      def council_for(code) = find(code)&.council
    end
  end
end
