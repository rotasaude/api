# Troca do responsável da família (contrato §14 L29; F-24.4). No LEDI trocar
# o responsável é família nova: o trigger families_guard segue proibindo a
# troca na própria família. Corpo `{ responsible: { patient_id }, version }`
# — `version` é a do DOMICÍLIO esperada (outra → stale_version, como no
# SaveFamily); o novo responsável é um morador com cadastro individual ATIVO
# da família antiga.
#
#   - A família antiga fica em mudança (moved_out: definitiva; stMudanca na
#     ficha — o jeito do LEDI de encerrar a família); a nova nasce ativa com o
#     novo responsável e copia membros, renda e "reside desde" da antiga.
#   - Os cadastros ATIVOS da família antiga passam para a nova: versão nova
#     (origin save, em nome de quem gravou, com o CBO dele, que precisa estar
#     na Tabela 1 — como a cascata da L28) + ficha individual; is_responsible
#     só do novo responsável; relacao_parentesco_cidadao sai de todos (era a
#     relação com o responsável antigo; a do responsável o LEDI proíbe).
#   - Tudo numa versão nova do domicílio + ficha domiciliar (SaveHousehold),
#     com o escopo de quem grava a ficha domiciliar (Access.registrar?
#     ficha: :household): out_of_scope | cbo_not_allowed.
#   - Travas: pacientes (moradores, com o novo responsável) → domicílio →
#     família → cadastros.
#   - Recusas: invalid_family (version | responsible.patient_id | moved_out),
#     stale_version e as do SaveHousehold. Evento family.responsible_replaced
#     só com ids (o household.saved sai pelo SaveHousehold).
module TerritoryRegistry
  module ReplaceResponsible
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    RESPONSIBLE = "responsible.patient_id".freeze
    KINSHIP = "relacao_parentesco_cidadao".freeze

    module_function

    def call(family:, params:, by:)
      params = params.to_h.stringify_keys
      return invalid("version") unless params["version"].is_a?(Integer)

      responsible = params["responsible"]
      patient_id = responsible.is_a?(Hash) ? responsible.stringify_keys["patient_id"] : nil
      return invalid(RESPONSIBLE) unless patient_id.is_a?(String) && patient_id.match?(UUID)

      household = family.household
      fresh = nil
      result = SaveHousehold.call(
        params: SaveHousehold.params_of(household).merge("version" => params["version"]), by: by, household: household,
        lock_patient_ids: [ patient_id ],
        before_version: ->(locked) { fresh = replace!(locked, family, patient_id, by) }
      )
      return result if result.failure?

      Result.ok(family: fresh, household: result.payload[:household], version: result.payload[:version])
    end

    # Sob as travas dos moradores e do domicílio: a família, depois os cadastros.
    def replace!(household, family, patient_id, by)
      family.lock!
      return invalid("moved_out") if family.moved_out

      registrations = IndividualRegistration.active_registrations.where(family_id: family.id).order(:id).lock.to_a
      return invalid(RESPONSIBLE) if patient_id == family.responsible_patient_id
      return invalid(RESPONSIBLE) unless registrations.any? { |registration| registration.patient_id == patient_id }
      return invalid(RESPONSIBLE) if household.families.active_families.exists?(responsible_patient_id: patient_id)

      area = household.micro_area
      scope = Access.registrar?(by, area.team, ficha: :individual, micro_area: area)
      return Result.fail(scope) unless scope == :ok

      family.update!(moved_out: true)
      fresh = Family.create!(household: household, moved_out: false, responsible_patient_id: patient_id,
                             members_count: family.members_count, income_band: family.income_band, living_since: family.living_since)
      move!(registrations, fresh, by, Access.membership(by, area.team).cbo_code)
      DomainEvents.publish("family.responsible_replaced", household_id: household.id, family_id: family.id, new_family_id: fresh.id,
                                                          user_id: by.id)
      fresh
    end

    def move!(registrations, fresh, by, cbo)
      at = Time.current
      registrations.each do |registration|
        moved = { family_id: fresh.id, is_responsible: registration.patient_id == fresh.responsible_patient_id }
        sociodemographic = registration.latest_version.sociodemographic
        changes = sociodemographic ? moved.merge(sociodemographic: sociodemographic.except(KINSHIP)) : moved
        version = SaveRegistration.append!(registration, origin: "save", saved_by_user_id: by.id, saved_by_professional_id: by.professional.id,
                                                         saved_cbo: cbo, changes: changes, at: at,
                                                         header: moved.merge(registered_at: at, registered_by_user_id: by.id))
        DomainEvents.publish("territory_registration.saved", registration_id: registration.id, registration_version_id: version.id,
                                                             patient_id: registration.patient_id, user_id: by.id)
      end
    end

    def invalid(path) = Result.fail(:invalid_family, details: { path: path })
    private_class_method :replace!, :move!, :invalid
  end
end
