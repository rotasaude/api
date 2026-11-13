# /home_visits/who_to_visit (contrato §8, §13; plano, Task 18, Desvio 11):
#   GET /home_visits/who_to_visit?micro_area_id=&reason[]=&before=&limit=
#       { items, next_before } (HomeVisits::WhoToVisit), com trilha
#       clinical_record.viewed (access "home_visits", os patient_ids da página)
#   GET /home_visits/who_to_visit/count?micro_area_id=
#       { care_line, registration_due, never_visited, people }, sem trilha
# Quem lê a microárea (HomeVisits::Access: o ACS na sua, o atribuído na dele,
# o enfermeiro/médico em qualquer uma da equipe); senão 403 out_of_scope;
# microárea desconhecida → 404. reason[] fora dos três códigos → 422
# invalid_request (path reason); limit fora de 1–100 → invalid_limit; cursor
# adulterado → invalid_cursor. Interruptores lidos aqui, fora de transação.
# Só ids e filtros na query (query_only!).
module HomeVisits
  class WhoToVisitController < BaseController
    LIST_KEYS = %i[micro_area_id reason before limit].freeze
    COUNT_KEYS = %i[micro_area_id].freeze

    def index
      return unless query_only!(*LIST_KEYS)

      area = readable_area!
      return unless area

      reasons = list_filter("reason", WhoToVisit::REASONS)
      limit = page_limit unless performed?
      return if performed?

      result = WhoToVisit.page(micro_area: area, before: request.query_parameters["before"].presence, limit: limit, reasons: reasons,
                               **flags)
      patient_ids = result[:items].map { |item| item[:patient_id] }
      Trail.people_listed!(user: Current.user, micro_area_id: area.id, patient_ids: patient_ids) if patient_ids.any?
      render json: result
    rescue WhoToVisit::InvalidCursor
      render_refusal("invalid_cursor")
    end

    def count
      return unless query_only!(*COUNT_KEYS)

      area = readable_area!
      return unless area

      render json: WhoToVisit.count(micro_area: area, **flags)
    end

    private

    def flags
      { today: Time.zone.today, care_lines: CareLines::Gate.usable?(Current.city), home_visits: HomeVisits::Gate.usable?(Current.city) }
    end

    # A microárea de micro_area_id que o usuário lê; nil = já respondeu.
    def readable_area!
      id = request.query_parameters["micro_area_id"]
      unless uuid?(id)
        render_refusal("invalid_request", path: "micro_area_id")
        return nil
      end

      area = MicroArea.includes(:team).find_by(id: id)
      unless area
        render_refusal("not_found")
        return nil
      end
      return area if Access.reads_micro_area?(Current.user, area)

      render_refusal("out_of_scope")
      nil
    end
  end
end
