# Grava os prazos das quatro cores (contrato §6; G5): os quatro obrigatórios,
# inteiros de 1 a 365, e a ordem vermelho <= amarelo <= verde <= azul (prazos
# iguais valem). Upsert das quatro linhas; evento só quando algum prazo muda.
module CareRegulation
  module SaveDeadlines
    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(deadlines: { "red" => 7, … }) |
    # fail(:invalid_request, details: { path: "<cor>" }) |
    # fail(:invalid_deadlines, details: { path: "<cor menos grave>" }).
    def call(attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      Catalog::COLORS.each do |color|
        value = attrs[color]
        return refuse(:invalid_request, color) unless value.is_a?(Integer) && Catalog::DEADLINE_DAYS.cover?(value)
      end
      Catalog::COLORS.each_cons(2) do |severe, lenient|
        return refuse(:invalid_deadlines, lenient) if attrs[lenient] < attrs[severe]
      end

      new_values = attrs.slice(*Catalog::COLORS)
      RegulationRiskDeadline.transaction do
        changed = Deadlines.all != new_values
        now = Time.current
        RegulationRiskDeadline.upsert_all(
          new_values.map { |color, days| { color: color, days: days, updated_at: now, updated_by_user_id: by.id } },
          unique_by: :color
        )
        DomainEvents.publish("care_regulation.settings_changed", user_id: by.id) if changed
      end
      Result.ok(deadlines: Deadlines.all)
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :refuse
  end
end
