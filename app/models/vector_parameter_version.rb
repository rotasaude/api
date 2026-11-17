# Versão dos parâmetros técnicos (módulo 35a; contrato §11). Só acréscimo
# (trigger): a vigente é a maior versão (VectorControl::Parameters.current).
class VectorParameterVersion < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"

  def inspect = "#<VectorParameterVersion id=#{id} version=#{version}>"
end
