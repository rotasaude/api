# Configuração do cabeçalho do arquivo BPA da cidade (contrato §6): linha
# única, editada pelo admin municipal com step-up (Billing::SaveSettings).
class BillingSetting < ApplicationRecord
  belongs_to :updated_by_user, class_name: "User"

  def self.current = find_by(singleton: true)
end
