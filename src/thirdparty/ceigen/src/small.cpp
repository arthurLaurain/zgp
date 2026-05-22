#include "small.h"
#include <eigen/Eigen/Dense>
#include <eigen/Eigen/SVD>

using Matrix2d = Eigen::Matrix<SCALAR, 2, 2>;
using Vector2d = Eigen::Matrix<SCALAR, 2, 1>;
using Matrix3d = Eigen::Matrix<SCALAR, 3, 3>;
using Vector3d = Eigen::Matrix<SCALAR, 3, 1>;
using Matrix4d = Eigen::Matrix<SCALAR, 4, 4>;
using Vector4d = Eigen::Matrix<SCALAR, 4, 1>;

extern "C"
{
    void computeInverseWithCheck4d(const SCALAR (*mat)[16], SCALAR (*inv)[16], bool *invertible)
    {
        Eigen::Map<const Matrix4d> m(*mat);
        Eigen::Map<Matrix4d> inverse(*inv);
        m.computeInverseWithCheck(inverse, *invertible);
    }

    void computeInverseWithCheck3d(const SCALAR (*mat)[9], SCALAR (*inv)[9], bool *invertible)
    {
        Eigen::Map<const Matrix3d> m(*mat);
        Eigen::Map<Matrix3d> inverse(*inv);
        m.computeInverseWithCheck(inverse, *invertible);
    }

    void computeInverseWithCheck2d(const SCALAR (*mat)[4], SCALAR (*inv)[4], bool *invertible)
    {
        Eigen::Map<const Matrix2d> m(*mat);
        Eigen::Map<Matrix2d> inverse(*inv);
        m.computeInverseWithCheck(inverse, *invertible);
    }

    void computeLogOnEigenValues2d(const SCALAR (*mat)[4], SCALAR (*out)[4])
    {
        using Matrix2d = Eigen::Matrix<SCALAR, 2, 2>;
        using Vector2d = Eigen::Matrix<SCALAR, 2, 1>;

        Eigen::Map<const Matrix2d> m(*mat);
        Eigen::Map<Matrix2d> r(*out);

        Eigen::SelfAdjointEigenSolver<Matrix2d> es(m);

        Matrix2d U = es.eigenvectors();
        Vector2d D = es.eigenvalues();

        const SCALAR eps = 1e-12;
        D = D.cwiseMax(eps);

        Vector2d logD = D.array().log();

        r = U * logD.asDiagonal() * U.transpose();

    }

    // Compute two 2x2 matrices for eigenvectors and eigenvalues.
    // First matrix is a square matrix where each column is an eigenvector.
    // Second matrix is diagonal matrix where each element is an eigenvalue.
    void computeEigenValuesAndEigenVectors2d(const SCALAR (*mat)[4], SCALAR (*eigenvectors)[4], SCALAR (*eigenvalues)[4])
    {
        Eigen::Map<const Matrix2d> m(*mat);
        Eigen::Map<Matrix2d> vectors(*eigenvectors);
        Eigen::Map<Matrix2d> values(*eigenvalues);

        Eigen::SelfAdjointEigenSolver<Matrix2d> es(m);

        vectors = es.eigenvectors();

        Vector2d evals = es.eigenvalues();
        values = evals.cwiseSqrt().asDiagonal();
    }

    // Compute two 3x3 matrices for eigenvectors and eigenvalues.
    // First matrix is a square matrix where each column is an eigenvector.
    // Second matrix is diagonal matrix where each element is an eigenvalue.
    void computeEigenValuesAndEigenVectors3d(const SCALAR (*mat)[9], SCALAR (*eigenvectors)[9], SCALAR (*eigenvalues)[9])
    {
        Eigen::Map<const Matrix3d> m(*mat);
        Eigen::Map<Matrix3d> vectors(*eigenvectors);
        Eigen::Map<Matrix3d> values(*eigenvalues);

        Eigen::SelfAdjointEigenSolver<Matrix3d> es(m);

        vectors = es.eigenvectors();

        Vector3d evals = es.eigenvalues();
        
        evals = evals.cwiseMax(0.0);
        values = evals.cwiseSqrt().asDiagonal();
    }

    void computeJacobiSVD2d(const SCALAR (*M)[4], SCALAR (*U)[4], SCALAR (*S)[4], SCALAR (*V)[4])
    {
        Eigen::Map<const Matrix2d> m(*M);
        Eigen::Map<Matrix2d> u(*U);
        Eigen::Map<Matrix2d> s(*S);
        Eigen::Map<Matrix2d> v(*V);

        Eigen::JacobiSVD<Matrix2d> svd(m, Eigen::ComputeFullU | Eigen::ComputeFullV);

        u = svd.matrixU();
        v = svd.matrixV();
        s = svd.singularValues().asDiagonal();
    }

    void computeJacobiSVD3d(const SCALAR (*M)[9], SCALAR (*U)[9], SCALAR (*S)[9], SCALAR (*V)[9])
    {
        Eigen::Map<const Matrix3d> m(*M);
        Eigen::Map<Matrix3d> u(*U);
        Eigen::Map<Matrix3d> s(*S);
        Eigen::Map<Matrix3d> v(*V);

        Eigen::JacobiSVD<Matrix3d> svd(m, Eigen::ComputeFullU | Eigen::ComputeFullV);

        u = svd.matrixU();
        v = svd.matrixV();
        s = svd.singularValues().asDiagonal();
    }

    void solveSymmetricLinearSystem4d(const SCALAR (*mat)[16], const SCALAR (*b)[4], SCALAR (*x)[4])
    {
        Eigen::Map<const Matrix4d> m(*mat);
        Eigen::Map<const Vector4d> bVec(*b);
        Eigen::Map<Vector4d> xVec(*x);
        Eigen::LDLT<Matrix4d> solver(m);
        xVec = solver.solve(bVec);
    }

    void eigenSolver3d(const SCALAR (*mat)[9], SCALAR (*eigenvalues)[3], SCALAR (*eigenvectors)[9])
    {
        Eigen::Map<const Matrix3d> m(*mat);
        Eigen::Map<Vector3d> evals(*eigenvalues);
        Eigen::Map<Matrix3d> evecs(*eigenvectors);
        Eigen::SelfAdjointEigenSolver<Matrix3d> solver(m);
        evals = solver.eigenvalues();
        evecs = solver.eigenvectors();
    }
}
