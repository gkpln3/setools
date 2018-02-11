# Copyright 2014, Tresys Technology, LLC
# Copyright 2017-2018, Chris PeBenito <pebenito@ieee.org>
#
# This file is part of SETools.
#
# SETools is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 2.1 of
# the License, or (at your option) any later version.
#
# SETools is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with SETools.  If not, see
# <http://www.gnu.org/licenses/>.
#

#
# Classes
#
cdef class PolicySymbol:

    """This is a base class for all policy objects."""

    cdef:
        readonly SELinuxPolicy policy

    def __hash__(self):
        return hash(str(self))

    def __eq__(self, other):
        try:
            # This is a regular Python function, so it cannot
            # access the handle (C) attribute since it is not
            # a Python object.  Call the low-level _eq method
            # for doing the pointer comparison.  If other is
            # not the same class as this, TypeError will be
            # raised as the _eq method must specify the type
            # so that handle is accessible.
            return self._eq(other)
        except TypeError:
            return str(self) == str(other)

    def __ne__(self, other):
        return not self == other

    def __lt__(self, other):
        # this is used by Python sorting functions
        return str(self) < str(other)

    def __repr__(self):
        return "<{0.__class__.__name__}({1}, \"{0}\")>".format(self, repr(self.policy))

    def _eq(self, other):
        raise NotImplementedError

    def statement(self):
        """
        A rendering of the policy statement.  This should be
        overridden by subclasses.
        """
        raise NotImplementedError


cdef class Ocontext(PolicySymbol):

    """Base class for most in-policy labeling statements, (portcon, nodecon, etc.)"""

    cdef sepol.ocontext_t *handle

    def _eq(self, Ocontext other):
        """Low-level equality check (C pointers)."""
        return self.handle == other.handle

    @property
    def context(self):
        """The context for this statement."""
        return Context.factory(self.policy, self.handle.context)

    def statement(self):
        return str(self)


#
# Iterator classes
#
cdef class PolicyIterator:

    """Base class for all policy object iterators."""

    cdef SELinuxPolicy policy

    def __iter__(self):
        return self

    def __next__(self):
        raise NotImplementedError

    def __len__(self):
        raise NotImplementedError

    def reset(self):
        """Reset the iterator to the start."""
        raise NotImplementedError


cdef class EbitmapIterator(PolicyIterator):

    """
    Base class for iterators over hash tables.

    Sublcasses must provide their own __next__, which calls this class's __next__
    and then uses a factory function to build and return an object from self.curr.

    For example:

    def __next__(self):
        super().__next__()
        return iomemcon_factory(self.policy, self.curr)
    """

    cdef:
        sepol.ebitmap_t *bmap
        sepol.ebitmap_node_t *node
        size_t curr
        size_t bit

    def __next__(self):
        if self.curr >= self.bmap.highbit:
            raise StopIteration

        # Returning the object is delegated
        # to subclasses which should returning
        # the object based off of self.bit
        self.bit = self.curr

        self.curr = sepol.ebitmap_next(&self.node, self.curr)
        while self.curr < self.bmap.highbit and not sepol.ebitmap_node_get_bit(self.node, self.curr):
            self.curr = sepol.ebitmap_next(&self.node, self.curr)

    def __len__(self):
        cdef:
            sepol.ebitmap_node_t *node
            size_t curr

        count = 0
        curr = sepol.ebitmap_start(self.bmap, &node)
        while curr < self.bmap.highbit:
            count += sepol.ebitmap_node_get_bit(node, curr)
            curr = sepol.ebitmap_next(&node, curr)

        return count

    def reset(self):
        """Reset the iterator back to the start."""
        self.curr = sepol.ebitmap_start(self.bmap, &self.node)

        # advance to first set bit
        while self.curr < self.bmap.highbit and not sepol.ebitmap_node_get_bit(self.node, self.curr):
            self.curr = sepol.ebitmap_next(&self.node, self.curr)


cdef class HashtabIterator(PolicyIterator):

    """
    Base class for iterators over hash tables.

    Sublcasses must provide their own __next__, which calls this class's __next__
    and then uses a factory function to build and return an object from self.curr.

    For example:

    def __next__(self):
        super().__next__()
        return iomemcon_factory(self.policy, self.curr)
    """

    cdef:
        sepol.hashtab_t *table
        sepol.hashtab_node_t *node
        sepol.hashtab_node_t *curr
        unsigned int bucket

    def _next_bucket(self):
        """Internal method for advancing to the next bucket."""
        self.bucket += 1
        if self.bucket < self.table[0].size:
            self.node = self.table[0].htable[self.bucket]
        else:
            self.node = NULL

    def _next_node(self):
        """Internal method for advancing to the next node."""
        if self.node != NULL and self.node.next != NULL:
            self.node = self.node.next
        else:
            self._next_bucket()
            while self.bucket < self.table[0].size and self.node == NULL:
                self._next_bucket()

    def __next__(self):
        #
        # Note: cython does not support the regular C pointer
        # dereferencing (e.g. *ptr), so the ptr[0] way is used below
        # to dereference self.table.
        #
        if self.table[0] == NULL or self.table[0].nel == 0 or self.bucket >= self.table[0].size:
            raise StopIteration

        # Returning the object is delegated
        # to subclasses which should returning
        # the objects based off of
        # self.node.key and/or self.node.datum
        self.curr = self.node
        self._next_node()

    def __len__(self):
        return self.table[0].nel

    def reset(self):
        """Reset the iterator to the start."""
        self.node = self.table[0].htable[0]

        # advance to first item
        if self.node == NULL:
            self._next_node()


cdef class OcontextIterator(PolicyIterator):

    """
    Base class for iterators for most in-policy labeling statements, (portcon, nodecon, etc.)

    Sublcasses must provide their own __next__, which calls this class's __next__
    and then uses a factory function to build and return an object from self.ocon.

    For example:

    def __next__(self):
        super().__next__()
        return iomemcon_factory(self.policy, self.ocon)
    """

    cdef:
        sepol.ocontext_t *head
        sepol.ocontext_t *ocon
        sepol.ocontext_t *curr

    def __next__(self):
        if self.curr == NULL:
            raise StopIteration

        # Returning the object is delegated
        # to subclasses which should returning
        # the ocon based off of self.ocon
        self.ocon = self.curr
        self.curr = self.curr.next

    def __len__(self):
        cdef:
            size_t count = 0
            sepol.ocontext_t *ocon = self.head

        while ocon:
            count += 1
            ocon = ocon.next

        return count
