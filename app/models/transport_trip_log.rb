# Diário de bordo do fechamento da viagem (ADR 0048): odômetro, abastecimentos
# e despesas (listas JSON). Imutável (trigger).
class TransportTripLog < ApplicationRecord
  belongs_to :transport_trip, inverse_of: :transport_trip_log
  belongs_to :closed_by_user, class_name: "User"
end
