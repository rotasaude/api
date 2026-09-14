# O convite do primeiro municipal_admin de uma cidade nova vem da plataforma
# (provisionamento, Plano 4): ainda não existe usuário na cidade para ser
# invited_by. A FK para users continua; só a obrigatoriedade sai. Aditiva.
class AllowPlatformInvitations < ActiveRecord::Migration[8.1]
  def change
    change_column_null :invitations, :invited_by_id, true
  end
end
