# Cadeia de frio (contrato §8; §15 V14 = D9 do dashboard; ADR 0047):
#   GET   /vaccination/cold_chain/equipments?location_id=  → { equipments }
#   POST  /vaccination/cold_chain/equipments               { location_id, name, kind, min_c, max_c, active } → 201 <equipamento>
#   PATCH /vaccination/cold_chain/equipments/:id           { name?, kind?, min_c?, max_c?, active? } → <equipamento>
#   POST  /vaccination/cold_chain/equipments/:id/readings  { read_at, current_c, min_c, max_c }
#         → 201 { reading, excursion_id|null, blocked_lots }
#   POST  /vaccination/cold_chain/excursions/:id/decide    { lots: [ { lot_id, decision, reason } ] } (step-up)
#         → { excursion_id, adjustments: [<adjustment do 27a>] }; 409 excursion_closed
#   GET   /vaccination/cold_chain/status?location_id=      → Vaccination::ColdChainStatus
#
# Local: sala de vacina (papel da equipe da sala ATIVA) ou rede de frio (papel
# de estoque do local ATIVO). Qualquer da equipe lê e registra leitura; o
# equipamento e a conduta são do `room_lead` (sala) ou do `stock_keeper` (rede
# de frio). Local inexistente ou que não é de vacina → 422 `location_id`;
# equipamento/excursão inexistente → 404; sem papel → 403 missing_role. Sem
# dado de paciente e sem trilha.
module Vaccination
  class ColdChainController < BaseController
    MANAGER_ROLES = %w[room_lead stock_keeper].freeze
    ADJUSTMENT_PRELOAD = [ { stock_location: :health_unit }, :stock_lot, { requested_by_user: :professional }, { decided_by_user: :professional } ].freeze

    def index
      return unless query_only!(:location_id)

      location = vaccine_location(params[:location_id]) or return render_refusal("location_id")
      return forbid if roles_at(location).empty?

      equipments = ColdChainEquipment.where(stock_location_id: location.id).order(:name, :id)
      render json: { equipments: equipments.map { |equipment| ColdChainStatus.equipment_json(equipment) } }
    end

    def create
      return unless query_only!

      location = vaccine_location(body_param("location_id")) or return render_refusal("location_id")
      return forbid unless manager?(location)

      result = SaveEquipment.call(attrs: body, location: location)
      return render_failure(result) if result.failure?

      render json: ColdChainStatus.equipment_json(result.payload[:equipment]), status: :created
    end

    def update
      return unless query_only!

      equipment = find_equipment or return
      return forbid unless manager?(equipment.stock_location)

      result = SaveEquipment.call(attrs: body, equipment: equipment)
      return render_failure(result) if result.failure?

      render json: ColdChainStatus.equipment_json(result.payload[:equipment])
    end

    def readings
      return unless query_only!

      equipment = find_equipment or return
      return forbid if roles_at(equipment.stock_location).empty?

      result = RecordReading.call(equipment: equipment, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      reading = ColdChainReading.includes(:excursion, recorded_by_user: :professional).find(result.payload[:reading].id)
      render json: { reading: ColdChainStatus.reading_json(reading), excursion_id: result.payload[:excursion]&.id,
                     blocked_lots: result.payload[:blocked_lots] }, status: :created
    end

    def decide
      return unless query_only!

      excursion = uuid?(params[:id]) ? ColdChainExcursion.includes(:stock_location).find_by(id: params[:id]) : nil
      return not_found unless excursion
      return forbid unless manager?(excursion.stock_location)

      require_step_up!
      return if performed?

      result = DecideExcursion.call(excursion: excursion, lots: body_param("lots"), by: Current.user, settings: Pharmacy::Settings.current)
      return render_failure(result) if result.failure?

      ids = result.payload[:adjustments].map(&:id)
      adjustments = StockAdjustment.includes(*ADJUSTMENT_PRELOAD).where(id: ids).index_by(&:id).values_at(*ids)
      catalog = Pharmacy::Json.catalog_for(adjustments.map { |adjustment| adjustment.stock_lot.catalog_item_id })
      render json: { excursion_id: excursion.id, adjustments: adjustments.map { |adjustment| Pharmacy::Json.adjustment(adjustment, catalog: catalog) } }
    end

    def status
      return unless query_only!(:location_id)

      location = vaccine_location(params[:location_id]) or return render_refusal("location_id")
      return forbid if roles_at(location).empty?

      render json: ColdChainStatus.call(location: location)
    end

    private

    # Local de vacina (sala ou rede de frio) pelo id; senão nil.
    def vaccine_location(id)
      uuid?(id) ? StockLocation.find_by(id: id, kind: Catalog::LOCATION_KINDS) : nil
    end

    def find_equipment
      equipment = uuid?(params[:id]) ? ColdChainEquipment.includes(:stock_location).find_by(id: params[:id]) : nil
      not_found unless equipment
      equipment
    end

    # Sala: papéis da equipe (sala ativa). Rede de frio: papéis de estoque (local ativo).
    def roles_at(location)
      if location.vaccine_room?
        room = VaccineRoom.find_by(stock_location_id: location.id)
        room&.active ? Access.room_roles(user: Current.user, room: room) : Set.new
      else
        location.active ? Access.cold_chain_roles(user: Current.user, location: location) : Set.new
      end
    end

    def manager?(location) = roles_at(location).intersect?(Set.new(MANAGER_ROLES))
  end
end
