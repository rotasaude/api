# Família do domicílio (contrato §4, §15.4 FamiliaRow; F-24.4). Corpo
# `{ responsible: { patient_id }, income_band, members_count, living_since,
# moved_out, version }` — `version` é a do DOMICÍLIO esperada. Cada gravação
# gera a versão seguinte do domicílio (com o retrato das famílias) e a ficha,
# pelo SaveHousehold, na mesma transação e com as mesmas travas (o
# responsável é travado junto dos moradores, Desvio 12; a família depois do
# domicílio). Responsável e domicílio nunca mudam (trigger); mudança grava
# moved_out e é definitiva. Recusas: invalid_family (path), stale_version e as
# do SaveHousehold (escopo, regras do domicílio).
module TerritoryRegistry
  module SaveFamily
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    RESPONSIBLE = "responsible.patient_id".freeze

    module_function

    def call(household:, params:, by:, family: nil)
      params = params.to_h.stringify_keys
      parsed = parse(params, family)
      return parsed if parsed.failure?

      attrs = parsed.payload
      ruled = Rules.family(attrs.slice(:members_count, :income_band, :living_since),
                           property_type: household.latest_version.property_type, on: Time.zone.today)
      return ruled if ruled.failure?

      saved = nil
      result = SaveHousehold.call(
        params: SaveHousehold.params_of(household).merge("version" => params["version"]), by: by, household: household,
        lock_patient_ids: [ attrs[:responsible_patient_id] ].compact,
        before_version: ->(locked) { (family ? update!(family, attrs) : create!(locked, attrs)).tap { |outcome| saved = outcome } }
      )
      return result if result.failure?

      Result.ok(family: saved, household: result.payload[:household], version: result.payload[:version])
    end

    def parse(params, family)
      return invalid("version") unless params["version"].is_a?(Integer)

      responsible = params["responsible"]
      patient_id = responsible.is_a?(Hash) ? responsible.stringify_keys["patient_id"] : nil
      if family
        return invalid(RESPONSIBLE) if !responsible.nil? && patient_id != family.responsible_patient_id
      else
        return invalid(RESPONSIBLE) unless uuid?(patient_id) && Patient.exists?(id: patient_id)
      end

      moved_out = params.fetch("moved_out", family ? family.moved_out : false)
      return invalid("moved_out") unless [ true, false ].include?(moved_out)
      return invalid("moved_out") if family.nil? && moved_out # nasce morando

      %w[income_band living_since].each { |key| return invalid(key) unless params[key].nil? || params[key].is_a?(String) }

      Result.ok(responsible_patient_id: (patient_id unless family), members_count: params["members_count"],
                income_band: params["income_band"], living_since: params["living_since"], moved_out: moved_out)
    end

    # Sob a trava do domicílio: um responsável ativo por domicílio.
    def create!(household, attrs)
      return invalid(RESPONSIBLE) if household.families.active_families.exists?(responsible_patient_id: attrs[:responsible_patient_id])

      Family.create!(household: household, moved_out: false, **attrs.slice(:responsible_patient_id, :members_count, :income_band, :living_since))
    end

    # A mudança é definitiva: família em mudança não volta nem muda mais.
    def update!(family, attrs)
      family.lock!
      return invalid("moved_out") if family.moved_out

      family.update!(attrs.slice(:members_count, :income_band, :living_since, :moved_out))
      family
    end

    def invalid(path) = Result.fail(:invalid_family, details: { path: path })
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    private_class_method :parse, :create!, :update!, :invalid, :uuid?
  end
end
