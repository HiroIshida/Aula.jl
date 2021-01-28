module AugLag

macro debugassert(test)
  esc(:(if $(@__MODULE__).debugging()
    @assert($test)
   end))
end
debugging() = false

using LinearAlgebra

struct QuadraticModel
    f::Float64
    grad::Vector{Float64}
    hessian::Matrix{Float64}
end

function newton_direction(qm::QuadraticModel)
    param_damping = 1.0 # Levenberg–Marquardt damping
    inv_hessian = inv(qm.hessian .+ param_damping)
    d = - inv_hessian * qm.grad
end

function (qm::QuadraticModel)(x::Vector{Float64})
    val = transpose(x) * qm.hessian * x + dot(qm.grad, x)  + qm.f
    grad = 2 * qm.hessian * x + qm.grad
    return val, grad
end

function psi(t::Float64, sigma::Float64, mu::Float64)
    if t - mu * sigma < 0.0
        val = - sigma * t + 1/(2*mu) * t^2
        return val
    else
        val = -0.5 * mu * sigma
        return val
    end
end

function psi_grad(t::Float64, sigma::Float64, mu::Float64)
    if t - mu * sigma < 0.0
        grad = - sigma + 1/mu * t
        return grad
    else
        return 0.0
    end
end

mutable struct AuglagData
    x::Vector{Float64} # current estimate for the solution
    lambda_ceq::Vector{Float64}
    lambda_cineq::Vector{Float64}
    mu_ceq::Float64
    mu_cineq::Float64
end

# we will consider a model with quadratic objective function with 
# general equality and inequality functions
struct Problem
    qm::QuadraticModel
    ceq::Function
    cineq::Function

    n_dim::Int
    n_dim_ceq::Int
    n_dim_cineq::Int
end

function gen_init_data(prob::Problem, x)
    lambda_ceq = zeros(prob.n_dim_ceq)
    lambda_cineq = zeros(prob.n_dim_cineq)
    mu_ceq = 1.0
    mu_cineq = 1.0
    AuglagData(x, lambda_ceq, lambda_cineq, mu_ceq, mu_cineq)
end

function Problem(qm::QuadraticModel, cineq, ceq, n_dim)
    x_dummy = zeros(n_dim)
    val_ceq, jac_ceq = ceq(x_dummy)
    n_dim_ceq = length(val_ceq)

    @assert size(jac_ceq) == (n_dim, n_dim_ceq)
    val_cineq, jac_cineq = cineq(x_dummy)

    n_dim_cineq = length(val_cineq)
    @assert size(jac_cineq) == (n_dim, n_dim_cineq)

    Problem(qm, cineq, ceq, n_dim, n_dim_cineq, n_dim_ceq)
end

function compute_auglag(prob::Problem, ad::AuglagData) 
    val_obj, grad_obj = prob.qm(ad.x)
    val_ceq, grad_ceq = prob.ceq(ad.x)
    val_cineq, grad_cineq = prob.cineq(ad.x)

    # compute function evaluation of the augmented lagrangian
    val_lag = val_obj
    for i in 1:length(ad.lambda_ceq)
        ineq_lag_mult = ad.lambda_ceq[i] * val_ceq[i]
        ineq_quadratic_penalty = ad.mu_ceq/2.0 * val_ceq[i]^2
        val_lag += (- ineq_lag_mult + ineq_quadratic_penalty)
    end
    for i in 1:length(ad.lambda_cineq)
        val_lag += psi(val_cineq[i], ad.lambda_cineq[i], ad.mu_cineq)
    end

    # compute gradient of the augmented lagrangian
    grad_lag = grad_obj
    for i in 1:prob.n_dim_ceq
        grad_ineq_lag_mult = ad.lambda_ceq[i] * grad_ceq[:, i]
        grad_ineq_quadratic_penalty = ad.mu_ceq/2.0 * 2 * val_ceq[i] * grad_ceq[:, i]
        grad_lag += (- grad_ineq_lag_mult + grad_ineq_quadratic_penalty)
    end
    for i in 1:prob.n_dim_cineq
        grad_lag += psi_grad(val_cineq[i], ad.lambda_cineq[i], ad.mu_cineq) * grad_cineq[:, i]
    end

    # compute approximate hessian of augmented lagrangian 
    approx_hessian = prob.qm.hessian
    for i in 1:prob.n_dim_ceq
        approx_hessian += 0.5 * ad.mu_ceq * grad_ceq[:, i] * transpose(grad_ceq[:, i])
    end
    for i in 1:prob.n_dim_cineq
        approx_hessian += 0.5 * ad.mu_cineq * grad_cineq[:, i] * transpose(grad_cineq[:, i]) 
    end

    return val_lag, grad_lag, approx_hessian
end

function step_auglag(prob::Problem, ad::AuglagData)
    for i in 1:20
        println("==================")
        for _ in 1:10
            # newton step
            val_lag, grad_lag, hessian_lag = compute_auglag(prob, ad)
            qm = QuadraticModel(val_lag, grad_lag, hessian_lag)
            direction = newton_direction(qm)
            ad.x += direction
            println(val_lag)
        end

        val_obj, grad_obj = prob.qm(ad.x)
        val_ceq, grad_ceq = prob.ceq(ad.x)
        val_cineq, grad_cineq = prob.cineq(ad.x)
        for j in 1:prob.n_dim_ceq
            ad.lambda_ceq[j] -= ad.mu_ceq * val_ceq[j]
        end
        for j in 1:prob.n_dim_cineq
            ad.lambda_cineq[j] = max(0.0, ad.lambda_cineq[j] - ad.mu_cineq * val_cineq[j])
        end
        println(ad)


        ad.mu_ceq *= 5.0
        ad.mu_cineq *= 5.0
    end
end

export QuadraticModel, AuglagData, Problem, compute_auglag, gen_init_data, step_auglag

end # module