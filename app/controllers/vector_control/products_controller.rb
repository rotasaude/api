# /vector_control/products (módulo 35a, ADR 0054; contrato §4, §12; Q8, Q15):
# os produtos de campo, só a coordenação (403 missing_role). Lista `{ items }`
# com todos (ativos e inativos), por código; escritas devolvem o
# VectorProduct, sem envelope. Corpo só JSON (query na escrita → 422).
# Módulo 35b (Q11): a vacina antirrábica e a coleira também moram aqui; a
# finalidade de zoonoses só com o zoonoses utilizável (lido aqui, fora da
# transação, e passado ao SaveProduct).
module VectorControl
  class ProductsController < BaseController
    # Q11 (35b): abre com o vector_control ou o zoonoses utilizável.
    skip_before_action :require_vector_control!
    before_action :require_vector_supplies!
    before_action(only: %i[create update]) { query_only! }
    before_action :coordinator!

    def index
      return unless query_only!

      render json: { items: Json.products(VectorProduct.order(:code, :id).to_a) }
    end

    def create
      result = SaveProduct.call(params: body, by: Current.user, zoonoses: zoonoses_usable?)
      return render_failure(result) if result.failure?

      render json: Json.product(result.payload.fetch(:product)), status: :created
    end

    def update
      product = uuid?(params[:id]) ? VectorProduct.find_by(id: params[:id]) : nil
      return not_found unless product

      result = SaveProduct.call(params: body, by: Current.user, product: product, zoonoses: zoonoses_usable?)
      return render_failure(result) if result.failure?

      render json: Json.product(result.payload.fetch(:product))
    end

    private

    def zoonoses_usable? = Zoonoses::Gate.usable?(Current.city)
  end
end
