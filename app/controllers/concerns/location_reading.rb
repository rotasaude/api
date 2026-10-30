# Leitura de estoque por local (posição, extrato e alertas): qualquer papel da
# farmácia no local, ou o almoxarife do central, que lê todos. Sem trilha: o
# estoque não tem dado pessoal. Local da query inexistente → 422; sem papel →
# 403 (sozinho).
module LocationReading
  extend ActiveSupport::Concern

  private

  def central_keeper?
    @central_keeper = Pharmacy::Access.central_keeper?(Current.user) if @central_keeper.nil?
    @central_keeper
  end

  def readable?(location)
    central_keeper? || Pharmacy::Access.roles_at(user: Current.user, location: location).any?
  end

  # `location_id` da query, existente e legível; senão responde (422 ou 403) e
  # devolve nil.
  def required_location
    raw = params[:location_id]
    location = uuid?(raw) ? StockLocation.find_by(id: raw) : nil
    if location.nil?
      render_refusal("location_id")
    elsif !readable?(location)
      forbid
    else
      return location
    end
    nil
  end

  # Ids dos locais lidos: o `location_id` (se vier) ou todos os que o usuário
  # lê. Sem local nenhum → 403. Responde e devolve nil nas recusas.
  def readable_location_ids
    return required_location&.then { |location| [ location.id ] } if params.key?(:location_id)

    locations = Pharmacy::Access.locations_for(Current.user)
    if locations.empty?
      forbid
      return nil
    end

    locations.map(&:id)
  end
end
