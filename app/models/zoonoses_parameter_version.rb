# Versão dos parâmetros técnicos do centro de zoonoses (módulo 35b; contrato
# §9). Só acréscimo (trigger): a vigente é a maior versão
# (Zoonoses::Parameters.current).
class ZoonosesParameterVersion < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"

  def inspect = "#<ZoonosesParameterVersion id=#{id} version=#{version}>"
end
