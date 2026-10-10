# app/controllers/clinical_documents/remume_controller.rb
# REMUME (ADR 0033; contrato §6): o recorte da cidade sobre o catálogo da
# plataforma. Item escondido (revisão), removido ou inexistente → 422
# invalid_catalog_item; controlado pode entrar (a cidade dispensa; a receita
# do 19c o bloqueia).
module ClinicalDocuments
  class RemumeController < BaseController
    before_action :require_reader_role, only: :index
    before_action :require_admin_role, except: :index
    before_action :require_step_up!, except: :index

    def index
      rows = CityMedication.order(:created_at, :id).to_a
      items = MedicationCatalogItem.where(id: rows.map(&:catalog_item_id)).index_by(&:id)
      render json: { items: rows.filter_map { |row| (item = items[row.catalog_item_id]) && row_json(item, row) } }
    end

    def create
      item = uuid?(body["catalog_item_id"]) && MedicationCatalogItem.prescribable.find_by(id: body["catalog_item_id"])
      return unprocessable("invalid_catalog_item") unless item

      unit_ids = body.fetch("unit_ids", [])
      return unprocessable("invalid_unit") unless valid_units?(unit_ids)

      row = CityMedication.find_or_initialize_by(catalog_item_id: item.id)
      created = row.new_record?
      row.update!(unit_ids: unit_ids.uniq, added_by_user: Current.user)
      render json: row_json(item, row), status: created ? :created : :ok
    end

    def destroy
      row = uuid?(params[:catalog_item_id]) && CityMedication.find_by(catalog_item_id: params[:catalog_item_id])
      return not_found unless row

      row.destroy!
      head :no_content
    end

    private

    def valid_units?(ids)
      ids.is_a?(Array) && ids.all? { |id| uuid?(id) } && HealthUnit.where(id: ids).count == ids.uniq.size
    end

    def row_json(item, row) = { catalog_item: Json.catalog_item(item), unit_ids: row.unit_ids }
  end
end
