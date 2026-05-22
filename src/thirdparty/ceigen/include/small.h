#pragma once

#include <stdbool.h>

#define SCALAR double

#ifdef __cplusplus
extern "C"
{
#endif /* __cplusplus */

    void computeInverseWithCheck4d(const SCALAR (*mat)[16], SCALAR (*inv)[16], bool *invertible);
    void computeInverseWithCheck3d(const SCALAR (*mat)[9], SCALAR (*inv)[9], bool *invertible);
    void computeInverseWithCheck2d(const SCALAR (*mat)[4], SCALAR (*inv)[4], bool *invertible);
    void computeJacobiSVD2d(const SCALAR (*mat)[4], SCALAR (*U)[4], SCALAR (*S)[4], SCALAR (*V)[4]);
    void computeJacobiSVD3d(const SCALAR (*mat)[9], SCALAR (*U)[9], SCALAR (*S)[9], SCALAR (*V)[9]);
    void computeLogOnEigenValues2d(const SCALAR (*mat)[4], SCALAR (*out)[4]);
    void computeEigenValuesAndEigenVectors2d(const SCALAR (*mat)[4], SCALAR (*eigenvectors)[4], SCALAR (*eigenvalues)[4]);
    void computeEigenValuesAndEigenVectors3d(const SCALAR (*mat)[9], SCALAR (*eigenvectors)[9], SCALAR (*eigenvalues)[9]);
    void solveSymmetricLinearSystem4d(const SCALAR (*mat)[16], const SCALAR (*b)[4], SCALAR (*x)[4]);
    void eigenSolver3d(const SCALAR (*mat)[9], SCALAR (*eigenvalues)[3], SCALAR (*eigenvectors)[9]);

#ifdef __cplusplus
}
#endif /* __cplusplus */