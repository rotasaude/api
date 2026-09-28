# GET /admin/api/neighborhoods — opções do seletor de bairro dos painéis (ADR
# 0023; decisão de 2026-09-28: o filtro vale para todos os papéis que leem
# /admin/api). Só leitura, mesma autorização dos painéis (BaseController:
# sessão + vínculo ativo, ou operador por grant); /territory é só do
# municipal_admin. Inclui inativos, marcados — o filtro vale para o
# histórico. Sem o envelope `data` (contrato combinado com o dashboard).
class Admin::Api::NeighborhoodsController < Admin::Api::BaseController
  def index
    rows = Neighborhood.order(:name).map { |n| { id: n.id, name: n.name, active: n.active } }
    render json: { neighborhoods: rows }
  end
end
