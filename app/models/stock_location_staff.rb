# Vínculo de um usuário a um local de estoque com um papel da farmácia (ADR
# 0045). O papel vale com a Membership ativa do mesmo papel E este vínculo
# ativo (Pharmacy::Access). Nunca é apagado nem muda: só é revogado, uma vez
# (trigger).
class StockLocationStaff < ApplicationRecord
  self.table_name = "stock_location_staff"

  belongs_to :stock_location, inverse_of: :staff
  belongs_to :user
  belongs_to :granted_by_user, class_name: "User"
  belongs_to :revoked_by_user, class_name: "User", optional: true

  scope :active, -> { where(revoked_at: nil) }
end
