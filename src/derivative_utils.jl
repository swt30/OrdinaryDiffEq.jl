function calc_tderivative!(integrator, cache, dtd1, repeat_step)
  @inbounds begin
    @unpack t,dt,uprev,u,f,p = integrator
    @unpack du2,fsalfirst,dT,tf,linsolve_tmp = cache

    # Time derivative
    if !repeat_step # skip calculation if step is repeated
      if DiffEqBase.has_tgrad(f)
        f.tgrad(dT, uprev, p, t)
      else
        tf.uprev = uprev
        tf.p = p
        derivative!(dT, tf, t, du2, integrator, cache.grad_config)
      end
    end

    f(fsalfirst, uprev, p, t)
    @. linsolve_tmp = fsalfirst + dtd1*dT
  end
end

"""
    calc_J!(integrator,cache,is_compos)

Interface for calculating the jacobian.

For constant caches, a new jacobian object is returned whereas for mutable
caches `cache.J` is updated. In both cases, if `integrator.f` has a custom
jacobian update function, then it will be called for the update. Otherwise,
either ForwardDiff or finite difference will be used depending on the
`jac_config` of the cache.
"""
function calc_J!(integrator, cache::OrdinaryDiffEqConstantCache, is_compos)
  @unpack t,dt,uprev,u,f,p = integrator
  if DiffEqBase.has_jac(f)
    J = f.jac(uprev, p, t)
  else
    error("Jacobian wrapper for constant caches not yet implemented") #TODO
  end
  is_compos && (integrator.eigen_est = opnorm(J, Inf))
  return J
end
function calc_J!(integrator, cache::OrdinaryDiffEqMutableCache, is_compos)
  @unpack t,dt,uprev,u,f,p = integrator
  J = cache.J
  if DiffEqBase.has_jac(f)
    f.jac(J, uprev, p, t)
  else
    @unpack du1,uf,jac_config = cache
    uf.t = t
    uf.p = p
    jacobian!(J, uf, uprev, du1, integrator, jac_config)
  end
  is_compos && (integrator.eigen_est = opnorm(J, Inf))
end

function calc_W!(integrator, cache::OrdinaryDiffEqMutableCache, dtgamma, repeat_step, W_transform=false)
  @inbounds begin
    @unpack t,dt,uprev,u,f,p = integrator
    @unpack J,W,jac_config = cache
    mass_matrix = integrator.f.mass_matrix
    is_compos = typeof(integrator.alg) <: CompositeAlgorithm
    alg = unwrap_alg(integrator, true)

    # calculate W
    new_W = true
    if DiffEqBase.has_invW(f)
      # skip calculation of inv(W) if step is repeated
      !repeat_step && W_transform ? f.invW_t(W, uprev, p, dtgamma, t) :
                                    f.invW(W, uprev, p, dtgamma, t) # W == inverse W
      is_compos && calc_J!(integrator, cache, true)

    else
      # skip calculation of J if step is repeated
      if repeat_step || (alg_can_repeat_jac(alg) &&
                         (!integrator.last_stepfail && cache.newton_iters == 1 &&
                          cache.ηold < alg.new_jac_conv_bound))
        new_jac = false
      else
        new_jac = true
        calc_J!(integrator, cache, is_compos)
      end
      # skip calculation of W if step is repeated
      if !repeat_step && (!alg_can_repeat_jac(alg) ||
                          (integrator.iter < 1 || new_jac ||
                           abs(dt - (t-integrator.tprev)) > 100eps(typeof(integrator.t))))
        if W_transform
          for j in 1:length(u), i in 1:length(u)
              W[i,j] = mass_matrix[i,j]/dtgamma - J[i,j]
          end
        else
          for j in 1:length(u), i in 1:length(u)
              W[i,j] = mass_matrix[i,j] - dtgamma*J[i,j]
          end
        end
      else
        new_W = false
      end
    end
    return new_W
  end
end

function calc_W!(integrator, cache::OrdinaryDiffEqConstantCache, dtgamma, repeat_step, W_transform=false)
  @unpack t,uprev,f = integrator
  @unpack uf = cache
  # calculate W
  uf.t = t
  isarray = typeof(uprev) <: AbstractArray
  iscompo = typeof(integrator.alg) <: CompositeAlgorithm
  if !W_transform
    if isarray
      J = ForwardDiff.jacobian(uf,uprev)
      W = I - dtgamma*J
    else
      J = ForwardDiff.derivative(uf,uprev)
      W = 1 - dtgamma*J
    end
  else
    if isarray
      J = ForwardDiff.jacobian(uf,uprev)
      W = I*inv(dtgamma) - J
    else
      J = ForwardDiff.derivative(uf,uprev)
      W = inv(dtgamma) - J
    end
  end
  iscompo && (integrator.eigen_est = isarray ? opnorm(J, Inf) : J)
  W
end

function calc_rosenbrock_differentiation!(integrator, cache, dtd1, dtgamma, repeat_step, W_transform)
  calc_tderivative!(integrator, cache, dtd1, repeat_step)
  calc_W!(integrator, cache, dtgamma, repeat_step, W_transform)
  return nothing
end
