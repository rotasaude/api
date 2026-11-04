# GET /psychosocial/prefill?patient_id&health_unit_id (ADR 0049; contrato P4,
# A-D4): a ESF do paciente para a matrícula, pela regra comum de equipe
# (CareLines::TeamPopulation.patient_teams: o cadastro individual do 24a, com
# territory_registry ligado; senão a consulta e o território do 11). Só a eSF
# ativa (tipo 70) conta como ESF: `{ esf_covered: true, esf_cnes` (o CNES da
# unidade da equipe; nulo se a unidade não tem — a matrícula então pede o
# CNES), `usf: { id, name }, team: { id, name } }`; senão tudo nulo e
# `esf_covered: false`. Equipe lotada no CAPS; paciente inexistente →
# 404. Sem trilha e sem dado clínico.
module Psychosocial
  class PrefillController < BaseController
    ESF_KIND = "70".freeze
    NONE = { esf_covered: false, esf_cnes: nil, usf: nil, team: nil }.freeze

    def show
      return unless query_only!("patient_id", "health_unit_id")

      query = request.query_parameters
      return unless staff_unit!(query["health_unit_id"])

      patient = uuid?(query["patient_id"]) ? Patient.find_by(id: query["patient_id"]) : nil
      return not_found unless patient

      team_id = CareLines::TeamPopulation.patient_teams([ patient.id ])[patient.id]
      team = team_id && HealthTeam.includes(:health_unit).find_by(id: team_id, kind: ESF_KIND, active: true)
      return render json: NONE unless team

      usf = team.health_unit
      render json: { esf_covered: true, esf_cnes: usf.cnes.presence, usf: { id: usf.id, name: usf.name },
                     team: { id: team.id, name: team.name } }
    end
  end
end
