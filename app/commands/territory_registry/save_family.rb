# Família do domicílio (contrato §4, §15.4 FamiliaRow; F-24.4). Corpo
# `{ responsible: { patient_id }, income_band, members_count, living_since,
# moved_out, version }` — `version` é a do DOMICÍLIO esperada. Cada gravação
# gera a versão seguinte do domicílio (com o retrato das famílias) e a ficha,
# pelo SaveHousehold, na mesma transação e com as mesmas travas (o
# responsável é travado junto dos moradores, Desvio 12; a família depois do
# domicílio). Responsável e domicílio nunca mudam (trigger); mudança grava
# moved_out e é definitiva. Recusas: invalid_family (path), stale_version e as
# do SaveHousehold (escopo, regras do domicílio).
#
# §14 L28: a família nova leva junto o cadastro individual ATIVO do
# responsável NESTE domicílio (family_id, is_responsible true, sem
# relacao_parentesco_cidadao — só de quem não é responsável), com versão nova
# (origin save, em nome de quem gravou a família, com o CBO dele, que precisa
# estar na Tabela 1 — como a troca de microárea do SaveHousehold) e ficha.
# Travas: responsável (com os moradores) → domicílio → família → cadastro.
# Como o responsável nunca muda, não há responsável anterior a desfazer.
module TerritoryRegistry
  module SaveFamily
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    RESPONSIBLE = "responsible.patient_id".freeze
    # relacaoParentescoCidadao: só com statusEhResponsavel = false.
    KINSHIP = "relacao_parentesco_cidadao".freeze

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
        before_version: lambda do |locked|
          saved = family ? update!(family, attrs) : create!(locked, attrs)
          next saved if family || saved.is_a?(Result)

          link_responsible!(locked, saved, by) || saved
        end
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

    # O cadastro ativo do responsável neste domicílio entra na família (L28);
    # nil quando não há o que mudar, a recusa do escopo como Result.
    def link_responsible!(household, family, by)
      registration = IndividualRegistration.active_registrations
                                           .where(household_id: household.id, patient_id: family.responsible_patient_id).lock.first
      return nil if registration.nil? || (registration.family_id == family.id && registration.is_responsible)

      area = household.micro_area
      scope = Access.registrar?(by, area.team, ficha: :individual, micro_area: area)
      return Result.fail(scope) unless scope == :ok

      at = Time.current
      linked = { family_id: family.id, is_responsible: true }
      sociodemographic = registration.latest_version.sociodemographic
      changes = sociodemographic ? linked.merge(sociodemographic: sociodemographic.except(KINSHIP)) : linked
      version = SaveRegistration.append!(registration, origin: "save", saved_by_user_id: by.id, saved_by_professional_id: by.professional.id,
                                                       saved_cbo: Access.membership(by, area.team).cbo_code, changes: changes, at: at,
                                                       header: linked.merge(registered_at: at, registered_by_user_id: by.id))
      DomainEvents.publish("territory_registration.saved", registration_id: registration.id, registration_version_id: version.id,
                                                           patient_id: registration.patient_id, user_id: by.id)
      nil
    end

    def invalid(path) = Result.fail(:invalid_family, details: { path: path })
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    private_class_method :parse, :create!, :update!, :link_responsible!, :invalid, :uuid?
  end
end
