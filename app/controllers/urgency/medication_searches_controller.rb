# Busca de medicamento da prescrição interna da UPA (ADR 0050; contrato §12
# Q4): POST /urgency/medication_search { query } → 200 `{ items: [{
# catalog_item_id, catmat_code, name, strength, dosage_form, unit,
# controlled_list }] }`. Sob urgency_care, SEM exigir clinical_documents; só o
# médico (225*) com vínculo ativo em alguma UPA (os demais → 403 pela
# Access.upa_refusal). Reusa a consulta do 19 (Medications::Search: todos os
# termos, sem acento, só o prescritível, a REMUME primeiro). O texto da busca
# vai só no CORPO (a URL e o log não o veem: `query` está em
# filter_parameters), de 2 a 60 caracteres. Sem catálogo → 503.
module Urgency
  class MedicationSearchesController < BaseController
    def create
      return unless query_only! && only_query!
      return forbid(Access.upa_refusal(Current.user).to_s) unless Access.upa_physician?(Current.user)

      query = body_param("query")
      unless query.is_a?(String) && query.strip.length.between?(Medications::Search::MIN_QUERY, Pharmacy::Catalog::SEARCH_QUERY_MAX)
        return render_refusal("query")
      end

      ids = Medications::Search.call(q: query).map { |hit| hit.fetch(:id) }
      catalog = Pharmacy::Json.catalog_for(ids)
      render json: { items: ids.filter_map { |id| catalog[id] && item(catalog[id]) } }
    rescue Medications::Search::Unavailable
      render json: { error: "catalog_unavailable" }, status: :service_unavailable
    end

    private

    def item(row)
      { catalog_item_id: row.id, catmat_code: row.catmat_code, name: row.active_ingredient, strength: row.strength,
        dosage_form: row.dosage_form, unit: row.unit, controlled_list: row.controlled_list }
    end

    def only_query!
      unknown = (body.keys - %w[query]).first
      return true unless unknown

      render_refusal(unknown.to_s[0, KEY_PATH_MAX])
      false
    end
  end
end
