# GET /psychosocial/options?health_unit_id (contrato P4, P31): o que as telas
# do CAPS escolhem — as listas do raas.yml e do catálogo; os procedimentos do
# CAPS (`procedure_prefixes` do raas.yml) da SIGTAP da competência corrente com instrumento
# RAAS-PSI, BPA-I ou BPA-C, já filtrados pelo CBO do vínculo de quem pede
# (relação de CBO vazia não restringe), com as marcas `family_care` e
# `collective`, a quantidade máxima (`max_quantity`, nulo = sem limite) e se
# exige autorização (`requires_authorization`, atributo 036) — P56, lidos pelo
# Billing::SigtapCache como na crítica da ação (ActionRules); a equipe lotada no CAPS (<pro>, CBO do vínculo mais antigo) e
# as equipes da APS ativas (o matriciamento). Só a equipe lotada; sem dado de
# paciente, sem trilha.
module Psychosocial
  class OptionsController < BaseController
    def show
      return unless query_only!("health_unit_id")

      unit = staff_unit!(params[:health_unit_id])
      return unless unit

      config = Raas.config
      competence = Time.zone.today.strftime("%Y%m")
      render json: {
        origins: pairs(config["origins"]), destinations: pairs(config["destinations"]), substances: pairs(config["substances"]),
        intensities: Catalog::INTENSITIES, places: Catalog::PLACES, group_kinds: Catalog::GROUP_KINDS,
        reception_outcomes: Catalog::RECEPTION_OUTCOMES, referral_priorities: Catalog::REFERRAL_PRIORITIES,
        night_sigtap_code: config["night_sigtap_code"], competence: competence,
        procedures: procedures(competence, @link.cbo_code, config), team: team(unit), health_teams: health_teams
      }
    end

    private

    def pairs(map) = map.map { |code, label| { code: code, label: label } }

    def procedures(competence, cbo, config)
      sigtap = Billing::SigtapCache.new
      release = sigtap.release(competence)
      return [] unless release

      prefixes = config["procedure_prefixes"].map { |prefix| "#{prefix}%" }
      instruments = SigtapProcedureInstrument.where(release_id: release.id, instrument_code: Catalog::INSTRUMENT_CODES.keys)
                                             .where("procedure_code LIKE ANY (ARRAY[?])", prefixes)
                                             .pluck(:procedure_code, :instrument_code)
                                             .group_by(&:first).transform_values { |rows| rows.map(&:last).sort }
      cbos = SigtapProcedureCbo.where(release_id: release.id, procedure_code: instruments.keys).pluck(:procedure_code, :cbo_code)
                               .group_by(&:first).transform_values { |rows| rows.map(&:last) }
      allowed = instruments.keys.select { |code| cbos[code].nil? || cbos[code].include?(cbo) }
      SigtapProcedure.where(release_id: release.id, code: allowed).order(:code).pluck(:code, :name).map do |code, name|
        { code: code, name: name, instrument_codes: instruments[code], family_care: config["family_care_codes"].include?(code),
          collective: config["collective_codes"].include?(code), max_quantity: sigtap.max_quantity(release, code),
          requires_authorization: sigtap.attributes(release, code).include?(ActionRules::AUTHORIZATION_ATTRIBUTE) }
      end
    end

    # A equipe lotada: papel do CAPS ativo e vínculo ativo no CAPS (o mais antigo dá o CBO).
    def team(unit)
      staff_ids = Membership.active.where(role: Access::STAFF_ROLES).select(:user_id)
      links = ProfessionalLink.active.where(health_unit_id: unit.id).joins(:professional)
                              .where(professionals: { user_id: staff_ids }).includes(professional: :user).order(:started_at, :id)
      links.uniq { |link| link.professional.user_id }.map { |link| Json.pro(link.professional.user, link.cbo_code) }
           .sort_by { |pro| [ pro["name"].to_s, pro["user_id"] ] }
    end

    def health_teams
      HealthTeam.where(active: true, kind: HealthTeam::PRIMARY_CARE_KINDS).joins(:health_unit).where(health_units: { active: true })
                .includes(:health_unit).order(:name, :id)
                .map { |team| { id: team.id, name: team.name, ine: team.ine, health_unit: { id: team.health_unit_id, name: team.health_unit.name } } }
    end
  end
end
