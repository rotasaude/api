# app/models/city_medication.rb
# Um item da REMUME da cidade (ADR 0033; spec §3): recorte do catálogo da
# plataforma, por id; unidades opcionais (vazio = toda a rede).
class CityMedication < ApplicationRecord
  self.table_name = "city_medication_list"

  belongs_to :added_by_user, class_name: "User"
end
