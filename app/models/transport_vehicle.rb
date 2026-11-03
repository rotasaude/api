# Veículo da frota (ADR 0048): placa (Mercosul ou antiga, sem hífen) e
# RENAVAM únicos, lugares sem o motorista e vagas de cadeirante. Nunca é
# apagado (trigger): desativa-se.
class TransportVehicle < ApplicationRecord
  belongs_to :updated_by_user, class_name: "User"
  has_many :transport_trips, inverse_of: :transport_vehicle, dependent: :restrict_with_error

  def inspect = "#<TransportVehicle id=#{id} kind=#{kind} active=#{active}>"
end
