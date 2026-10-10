# app/controllers/clinical_documents/nursing_protocols_controller.rb
# Protocolos de enfermagem (ADR 0033; contrato §6). Leitura: admin e
# profissional (a enfermeira escolhe o protocolo na receita). Escrita: admin
# com step-up. O catálogo é lido FORA da transação da cidade.
module ClinicalDocuments
  class NursingProtocolsController < BaseController
    ERRORS = { already_exists: :conflict }.freeze

    before_action :require_reader_role, only: :index
    before_action :require_admin_role, except: :index
    before_action :require_step_up!, except: :index

    def index
      protocols = NursingProtocol.includes(versions: :items).order(:year, :number).to_a
      ids = protocols.flat_map { |p| p.versions.flat_map { |v| v.items.map(&:catalog_item_id) } }
      catalog = MedicationCatalogItem.where(id: ids.uniq).index_by(&:id)
      render json: { items: protocols.map { |protocol| Json.protocol(protocol, catalog: catalog) } }
    end

    def create
      respond(NursingProtocols::Save.create(params: body, by: Current.user, catalog: catalog_for(body)), :created)
    end

    def add_version
      protocol = uuid?(params[:id]) && NursingProtocol.find_by(id: params[:id])
      return not_found unless protocol

      respond(NursingProtocols::Save.add_version(protocol: protocol, params: body, by: Current.user, catalog: catalog_for(body)), :created)
    end

    private

    def catalog_for(params) = MedicationCatalogItem.where(id: NursingProtocols::Save.catalog_ids(params)).index_by(&:id)

    def respond(result, status)
      return render_failure(result, ERRORS) if result.failure?

      protocol = result.payload[:protocol].reload
      ids = NursingProtocolVersionItem.joins(:nursing_protocol_version)
                                      .where(nursing_protocol_versions: { nursing_protocol_id: protocol.id }).pluck(:catalog_item_id)
      render json: Json.protocol(protocol, catalog: MedicationCatalogItem.where(id: ids.uniq).index_by(&:id)), status: status
    end
  end
end
