# Prestadores elegíveis para o TFD (contrato §6; §14 T7): ativos e fora da
# rede própria. Fonte única para as opções do médico, o laudo
# (Tfd::SaveCase) e o atendimento marcado pela comissão (Tfd::SetAppointment).
module Tfd
  module Providers
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def eligible = CareProvider.active_providers.where.not(kind: "own")

    # -> CareProvider elegível | nil (id ausente, malformado, inativo, próprio ou inexistente)
    def find(id) = id.is_a?(String) && id.match?(UUID) ? eligible.find_by(id: id) : nil
  end
end
