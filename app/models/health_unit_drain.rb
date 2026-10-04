# Esvaziamento de unidade (api#29; F-09.3): quem moveu, de qual unidade, para
# qual, por quê e quantos pedidos e horários. Só acréscimo (trigger).
class HealthUnitDrain < ApplicationRecord
  belongs_to :health_unit
  belongs_to :target_unit, class_name: "HealthUnit"
  belongs_to :drained_by_user, class_name: "User"
end
